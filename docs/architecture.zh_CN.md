# 架构

**中文** | [English](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/architecture.md)

Broker 对所有可变 MQTT 状态采用单写入者运行时。连接任务拥有 socket 和字节
buffer，不能直接修改 Session、订阅、保留消息或持久化状态。

```text
TCP、TLS、WS 或 WSS 连接
  ├─ reader → 有界 frame decoder → 协议 adapter → runtime event queue
  ├─ writer ← 有界 outbound queue ← 有序 runtime action
  └─ closer → 连接 generation 和终止原因处理
                                      │
                                      ▼
                                 RouterDriver
                                      │
                                      ▼
              BrokerRuntime + BrokerState（单写入者）
                ├─ Session 和 Packet ID 所有权
                ├─ SubscriptionIndex 和 RetainedStore
                ├─ 身份认证和授权决策
                └─ snapshot revision 和指标
```

## 协议边界

`src/framing` 将有界 TCP 字节流转换为完整 MQTT frame。`src/protocol_adapter`
拥有项目的 packet model，并隔离第三方 codec。packet 到达 Broker 状态前会校验
方向、flags、大小以及受支持的 QoS 组合。

非法输入、第一个 packet 无效、重复 CONNECT 或不支持的流程只会关闭
受影响的连接。

## 状态和路由

`BrokerState` 是确定性的，不包含 socket、task、clock 或文件句柄。它消费 event
并返回有序 action。订阅索引按两个方向维护，重叠 filter 按最高有效 QoS 合并，
投递顺序依据原始 UTF-8 字节，而不是 map 迭代顺序。

每个 Persistent Session 拥有自己的 Packet ID allocator、有序出站 inflight
条目和离线 QoS 1/2 FIFO。重连时先发送 CONNACK，再用原 Packet ID 按阶段
重放 DUP=1 的 PUBLISH 或 PUBREL，最后提升 queued message。每个 Session 和全局上限会约束 retained、
subscription、inflight、pending、connection、event 和 transport queue。

## 连接隔离

每个接受的 transport 都会分配单调递增的连接 generation。Client ID 接管会关闭
旧 generation；来自旧 socket 的延迟 reader/writer event 会成为 no-op。出站
queue 满只断开相应慢消费者，有界全局 event queue 则通过背压避免丢弃已解码
packet。

TLS 与明文 TCP 使用相同 transport 接口。凭据会在监听前校验，每个已接受连接的
握手都有独立 deadline。

## 持久化

启用 `--data-dir` 后，运行时将不可变 Snapshot V3 值导出到容量为一、
latest-wins 的 writer：

```text
state revision → debounce/max-delay → snapshot writer
  → 临时文件 → 文件同步 → 原子替换 → 目录同步
```

只有最近一次成功提交是持久的。系统在创建 listener 前校验完整文件并导入状态。
这是默认快照模式。可选 strict 模式使用本机 WAL，在对应确认前提交约定的
持久状态；不确定写入会封锁后续持久变更。准确的失败契约
见[本地持久化](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/persistence.zh_CN.md)。

## 安全和运维

身份认证产生 `Principal`，ACL 检查在状态修改前执行。Persistent Session 会在
重启后保留 owner，从而防止其他 Principal 接管或删除同一 Client ID。日志不会
记录密码、哈希、私钥、ACL 内容或 payload。

指标属于当前进程，不写入快照。`$SYS/broker/#` 消息使用隔离的 QoS 0 路径，
不会自计数，也不占用 retained 容量，但仍要求显式匹配的订阅和 ACL。

## QoS 2 交换边界

首次准入的 QoS 2 PUBLISH 在单写者事件中一并提交入站 Packet ID、路由和 retained
变化，采用 MQTT 3.1.1 Method B。同一个尚未完成的 ID 再次出现时只回复 PUBREC，
不依赖 DUP，也不按重复报文替换原 payload。PUBREL 删除入站记录并回复 PUBCOMP；
未知 PUBREL 也回复 PUBCOMP。ACL 拒绝的发布保留有界握手记录，但不路由。

出站 QoS 1/2 共用 Packet ID 和 inflight 窗口。PUBREC 释放 QoS 2 的 topic/payload，
保留 AwaitPubcomp 槽；PUBCOMP 才释放 ID 并提升 pending FIFO。持久重连先发 CONNACK，
再按阶段重放原 ID、DUP=1 的 PUBLISH，或固定头为 0x62 的 PUBREL。
未知 PUBREC 无状态回复 PUBREL；现存交换收到错误阶段的确认会关闭连接。

QoS 保证针对每段 MQTT 交换，降级为 QoS 1 的下游仍可能重复。
快照模式的 PUBREC/PUBCOMP 不代表已 fsync，恢复以最近成功快照为边界；
strict 模式先提交相应的持久状态 WAL 记录再确认。两种模式均不承诺端到端
业务 exactly-once 或存储设备损坏后的数据完整性。

## 管理路径

可选 loopback HTTP 监听器持有有界 socket、解析缓冲区、请求租约、
按作用域划分的令牌和独立限流桶。健康、指标及状态摘要读取类型化
观测缓存。明细 HTTP handler 把类型化查询送入固定槽位和代际邮箱；
只有 RouterDriver 读取可选的 Session、订阅、retained 和连接元数据
索引。单页只扫描有界的物理槽，不复制载荷或排序整个 Broker 状态。

写 handler 校验作用域、强 ETag 和幂等键，再由单写者原子接纳
Operation 并排队命令。离线删除重新核对 Session 生命周期，复用
BrokerState.apply 完成资源结算与其他会话推进动作的派发。kick
安装精确 ConnectionId 关闭意图，沿 supervisor terminal 路径执行，
在注销及该连接关联的原生认证任务真正 reap 后才成功。HTTP 响应
丢失不撤销已接纳效果。Operation、游标和审计表有固定容量与有界
维护；审计环只在内存中，满时覆盖旧事件。管理索引异常会停用明细
与写接口，但不改变 MQTT 业务状态。观测和管理事件与 MQTT 控制、
数据事件共用公平 EventBus 调度。
