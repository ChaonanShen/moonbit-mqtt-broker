# 兼容性和支持矩阵

**中文** | [English](compatibility.md)

| 能力 | 当前状态 | 说明 |
| --- | --- | --- |
| Linux x86_64 Native 构建 | 支持 | 固定 Docker 和 CI 路径 |
| MQTT 3.1.1 CONNECT / CONNACK | 支持 | 完整 Clean/Persistent `session_present` 语义 |
| TCP 拆包/粘包 framing | 支持 | 感知容量的 reader 和有界三态 decoder |
| 相同 packet/receive 上限 | 支持 | 16/16 边界覆盖完整 CONNECT 加粘连 PINGREQ |
| QoS 0/1 packet codec | 支持 | 完整 frame adapter；校验 Packet ID/DUP 组合 |
| MQTT.js 5.15.2 互操作 | 0.1.0 支持 | QoS 0/1、retained/Will、Persistent Session 和跨进程重启 |
| Mosquitto 2.0.18 互操作 | 0.1.0 支持 | QoS 0/1、retained 和 Persistent Session 离线重启投递 |
| Aedes 1.1.1 参考矩阵 | 仅测试 | 比较规范化的公共行为；不是运行时依赖，也不声明插件兼容性 |
| Topic 校验与路由 | 支持 | `+`、`#`、`$SYS`、重叠合并和确定性顺序 |
| Keep Alive 和 PING | 支持 | 1.5 倍 deadline；零表示禁用空闲超时 |
| Client ID 接管 | 支持 | 使用连接 generation 隔离旧事件 |
| Retained 投递 | 支持 | 实时 `RETAIN=0`、重放 `RETAIN=1`、空 payload 删除 |
| QoS 0/1 Will | 支持 | EOF、I/O/协议失败、超时和接管；DISCONNECT 抑制 |
| 网络 SUBACK / UNSUBACK | 支持 | 保留输入 Packet ID 和订阅顺序 |
| 空 Client ID | Clean Session 时支持 | 使用进程内唯一 ID |
| QoS 1 PUBACK / inflight | 支持 | 入站使用同 ID PUBACK；每个 Session 独立出站 ID 和有序 inflight |
| `clean_session=false` | 非空 Client ID 时支持 | 空 ID 返回 `IdentifierRejected` |
| Persistent Session | 跨连接支持 | 订阅、inflight 和有界离线 QoS 1 可在重连后恢复 |
| 重连 DUP 重放 | 支持 | 原 inflight 保留 Packet ID，并设置 `DUP=1` |
| Snapshot V2 数据边界 | 支持 | 保存 Principal 和 detach epoch；读取旧 V1 并重写 V2 |
| Broker 重启后状态 | 设置 `--data-dir` 时支持 | debounce 本地快照，恢复到最近提交 revision |
| SIGTERM / SIGINT 退出 | 支持 | 正常停止、抑制活动 Will、强制并排空最新 Snapshot |
| TLS listener | 可选支持 | 单个纯 TLS listener；启动时校验 PEM，握手有界 |
| MQTT.js/Mosquitto TLS | 0.1.0 支持 | QoS 0/1、retained、Persistent Session 和重启恢复 |
| Argon2id 认证 | 可选支持 | 只接受编码哈希；默认允许匿名 |
| 静态仅允许式 ACL | 可选支持 | 读/写过滤、部分 SUBACK、禁止客户端写 `$SYS` |
| Principal 所有 Client ID | 支持 | 跨 Principal 接管、清理和恢复在重启后仍被拒绝 |
| Persistent Session 过期 | 可选支持 | 默认永不过期；排除活动 Session；有界确定性扫描 |
| `$SYS/broker` 指标 | 支持 | 需显式订阅/读 ACL；QoS 0、不 retained、不持久化/自计数 |
| 文本/JSON 结构化日志 | 支持 | error/warn/info/debug，字段稳定并隐藏 secret/payload |
| TOML 配置 | 支持 | CLI > TOML > 默认值；未知/重复键致命；支持检查/打印模式 |
| QoS 2 / MQTT 5 | 不支持 | 明确拒绝/不在范围内 |
| WebSocket | 不支持 | 不在当前版本范围内 |
| 共享订阅 / Bridge / 插件 / 集群 | 不支持 | 仅单机 Broker |
| 外部数据库 / WAL / 零丢失持久化 | 不支持 | 仅最近提交的本地快照 |

CONNECT 必须是第一个 packet。非法 frame、超大声明、方向错误、重复 CONNECT、
QoS 2 或其他不支持的流程都会关闭连接。客户端发出的 QoS 1 publication 如果
超过 Session inflight/pending 资源，会被原子拒绝且不返回 PUBACK，客户端可以
按其 Session 生命周期重试。QoS 1 Will/内部 publication 只丢弃容量已满的
接收方，并继续向健康接收方路由。

receive-buffer 上限作用于尚未解码的缓冲字节。测试覆盖了恰好达到上限的 packet、
部分 prefix 后跟粘连 suffix，以及多个流水线 control packet。声明过大和非法
packet 会在产生无界缓冲前关闭连接。

Broker 不会在保持连接期间周期性重传。Persistent Session 恢复时会重传未确认的
出站 QoS 1。启用持久化后，retained、持久订阅、inflight/pending QoS 1、原始
Packet ID 和下一个 Packet ID 可跨 Broker 重启。Clean Session、离线 QoS 0、
连接、Keep Alive timer 和尚未触发的 Will 不会持久化。

这不是完全持久或零丢失的 Broker。崩溃时 debounce 窗口内的变更可能丢失；恢复
边界是最近一次成功提交的快照。主快照损坏会阻止启动，而不是被忽略或用旧临时
数据替换。

发布验证会将规范化的公共矩阵与 Mosquitto 2.0.18 和 Aedes 1.1.1 比较。
当一个客户端同时具有重叠的 QoS 0 与 QoS 1 订阅时，Mosquitto 可能选择 QoS 0；
MQTT 3.1.1 第 3.3.5 节要求使用所有匹配订阅的最高 QoS。因此 MoonBit 精确矩阵
仍要求一次 QoS 1 投递，而差异矩阵在该参考偏差场景中只比较投递数和 payload。
Aedes 仅作为行为参考，Broker 不链接任何 Aedes 源码。

TLS 使用固定的 `moonbitlang/async@0.20.6`、基于 OpenSSL 的 Native transport。
listener 只能选择明文或 TLS，不能同时提供两者。不声明支持 mTLS、SNI 路由、
证书热加载、多 listener 或 Windows TLS。该依赖目前将服务端 TLS 构造器标记为
experimental；本版本固定其精确版本，并在 CI 中验证启动、拒绝、互操作、并发、
退出和重启行为。

支持的 `$SYS/broker` 指标包括版本、uptime、已连接客户端、Session、订阅、
retained、QoS 1 inflight/pending、收发/丢弃消息、认证失败、ACL 拒绝、TLS
握手失败和持久化状态。根据 MQTT 3.1.1，单独的 `#` 订阅不匹配 `$SYS`。
