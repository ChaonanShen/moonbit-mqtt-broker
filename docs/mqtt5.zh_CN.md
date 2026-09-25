# MQTT 5 支持

**中文** | [English](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/feat/mqtt5-protocol/docs/mqtt5.md)

MQTT 5 默认关闭。启动时传入 --mqtt5-enabled true，或在 TOML 的
[protocol] 中设置 mqtt5_enabled = true。开启后，同一个 TCP、TLS、WS
或 WSS 监听器同时接收 MQTT 3.1.1 和 MQTT 5 客户端。关闭新连接入口
不会删除已有持久会话。

## 协议行为

Broker 支持两个版本的 QoS 0/1/2、保留消息、通配订阅、Will、
Keep Alive 和持久会话恢复。MQTT 5 增加 Clean Start、Session Expiry、
Message Expiry、Will Delay、No Local、Retain As Published、
Retain Handling、Subscription Identifier、Topic Alias、
Receive Maximum 和 Maximum Packet Size。Payload Format Indicator、
Content Type、Response Topic、Correlation Data 与有序 User Properties
可随实时、离线和保留消息传递。

Message Expiry 为 0 的合法发布仍获确认，但不向下游投递；带 RETAIN 时
会清除旧保留消息。持久会话的 armed/pending Will 按存储模式恢复；
临时会话的 armed Will 不能跨进程崩溃保存。

本次不实现共享订阅。CONNACK 宣告 Shared Subscription Available = 0；
共享过滤器返回 SUBACK 9E。不支持 Enhanced Authentication 方法，CONNECT
返回 8C。Broker 不自动生成 Response Information 命名空间，也不重定向客户端。

两个版本共用用户名密码、Principal 归属与 ACL。传输凭证时应使用 TLS 或 WSS。

## 配置

~~~toml
[server]
listen = "0.0.0.0:1883"

[protocol]
mqtt5_enabled = true
server_receive_maximum = 16
server_keep_alive = -1
topic_alias_maximum = 32
max_property_bytes = 16384
max_user_properties = 64
max_subscription_entries = 256
max_alias_bytes_per_connection = 65536
max_delayed_wills = 1024
max_expiry_work_per_turn = 128
write_timeout_ms = 10000

[persistence]
mode = "strict"
data_dir = "/var/lib/moonbit-mqtt-broker"
~~~

协议参数修改后须重启。对应 CLI 参数以 --mqtt5- 开头；--help 和
--print-effective-config 可显示完整生效配置。启用 MQTT 5 时，
server_receive_maximum 不得超过每会话入站 QoS 2 上限；
max_delayed_wills 不得超过会话与连接容量之和。

## 持久化与升级

off 只保留内存状态。snapshot 恢复最近一次完成写入的 V5 快照，崩溃时
可能损失 debounce 窗口内的变更。strict 在释放相应网络结果之前，将持久
会话、保留消息、订阅和 Will 变更写入 schema 6 WAL，也持久记录到期或
超大待发副本的清理。已提交 MQTT 交换在崩溃后仍可能重传，不等于应用层
恰好一次处理。

首次启用 MQTT 5 时，旧 V1/V2/V3 快照或旧 strict WAL 会迁移。升级前
备份数据目录和对应安全配置。旧程序不能直接读取升级后的 schema 6；
回滚须恢复升级前备份。权威文件损坏时 Broker 拒绝启动。

管理连接详情新增协议版本、对端限制与收发窗口占用；会话及订阅详情新增
保留方式、到期、Will 和订阅选项。状态与 Prometheus 仅增加固定维度的
版本、Will、窗口和别名聚合计数，不将消息内容、凭证或 User Properties
写入指标标签。

运行 scripts/verify-mqtt5-docker.sh 可验证单测、三种持久化模式与
TCP/TLS/WS/WSS 网络矩阵。脚本输出远端 MQTT5_EVIDENCE_DIR。
其他保证见[兼容性](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/feat/mqtt5-protocol/docs/compatibility.zh_CN.md)与[持久化](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/feat/mqtt5-protocol/docs/persistence.zh_CN.md)。
