# 架构

**中文** | [English](architecture.md)

Broker 对所有可变 MQTT 状态采用单写入者运行时。连接任务拥有 socket 和字节
buffer，不能直接修改 Session、订阅、保留消息或持久化状态。

```text
TCP 或 TLS 连接
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

非法输入、第一个 packet 无效、重复 CONNECT、QoS 2 或不支持的流程只会关闭
受影响的连接。

## 状态和路由

`BrokerState` 是确定性的，不包含 socket、task、clock 或文件句柄。它消费 event
并返回有序 action。订阅索引按两个方向维护，重叠 filter 按最高有效 QoS 合并，
投递顺序依据原始 UTF-8 字节，而不是 map 迭代顺序。

每个 Persistent Session 拥有自己的 Packet ID allocator、有序出站 inflight
条目和离线 QoS 1 FIFO。重连时先发送 CONNACK，再用原 Packet ID 和 `DUP=1`
重放 inflight，最后提升 queued message。每个 Session 和全局上限会约束 retained、
subscription、inflight、pending、connection、event 和 transport queue。

## 连接隔离

每个接受的 transport 都会分配单调递增的连接 generation。Client ID 接管会关闭
旧 generation；来自旧 socket 的延迟 reader/writer event 会成为 no-op。出站
queue 满只断开相应慢消费者，有界全局 event queue 则通过背压避免丢弃已解码
packet。

TLS 与明文 TCP 使用相同 transport 接口。凭据会在监听前校验，每个已接受连接的
握手都有独立 deadline。

## 持久化

启用 `--data-dir` 后，运行时将不可变 Snapshot V2 值导出到容量为一、
latest-wins 的 writer：

```text
state revision → debounce/max-delay → snapshot writer
  → 临时文件 → 文件同步 → 原子替换 → 目录同步
```

只有最近一次成功提交是持久的。系统在创建 listener 前校验完整文件并导入状态。
此存储设计是本地快照，不是 WAL，也不提供逐 PUBACK 同步持久性。准确的失败契约
见[本地持久化](persistence.zh_CN.md)。

## 安全和运维

身份认证产生 `Principal`，ACL 检查在状态修改前执行。Persistent Session 会在
重启后保留 owner，从而防止其他 Principal 接管或删除同一 Client ID。日志不会
记录密码、哈希、私钥、ACL 内容或 payload。

指标属于当前进程，不写入快照。`$SYS/broker/#` 消息使用隔离的 QoS 0 路径，
不会自计数，也不占用 retained 容量，但仍要求显式匹配的订阅和 ACL。
