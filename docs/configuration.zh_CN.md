# 配置

**中文** | [English](configuration.md)

配置优先级为：命令行参数 > TOML > 内置默认值。Broker 使用维护中的
`bobzhang/toml`；TOML 格式错误、重复键、未知 section/键和类型错误均为
致命错误。

```toml
[server]
listen = "0.0.0.0:8883"
max_connections = 128
max_packet_size = 1048576
max_receive_buffer_size = 1048576
max_outbound_queue = 64
max_runtime_events = 512
connect_timeout_ms = 10000
keep_alive_check_interval_ms = 100

[broker]
max_subscriptions_per_session = 128
max_subscriptions_total = 16384
max_retained_messages = 1024
max_sessions = 1024
max_inflight_per_session = 16
max_inflight_total = 512
max_pending_per_session = 64
max_pending_total = 1024
max_inbound_qos2_per_session = 64
max_inbound_qos2_total = 4096
persistent_session_expiry = "30d"
max_session_expirations_per_tick = 128

[persistence]
mode = "snapshot"
data_dir = "/var/lib/moonbit-mqtt-broker"
max_snapshot_bytes = 67108864
snapshot_debounce_ms = 250
snapshot_max_delay_ms = 2000
snapshot_retry_ms = 1000

[tls]
cert = "/etc/moonbit-mqtt-broker/server.crt"
key = "/run/secrets/server.key"
handshake_timeout_ms = 10000

[security]
allow_anonymous = false
password_file = "/run/secrets/passwords"
acl_file = "/etc/moonbit-mqtt-broker/acl"
auth_workers = 1
auth_queue_limit = 16
auth_timeout_ms = 10000
auth_poll_interval_ms = 5
auth_result_batch_limit = 16
auth_shutdown_grace_ms = 10000

[observability]
system_metrics_interval_ms = 10000
log_format = "json"
log_level = "info"
```

`--check-config` 会验证 TOML 及其引用的 TLS/安全文件，但不会监听端口、
获取持久化锁、打开持久化文件或创建数据目录。选择同步 WAL 时，在提供
`data_dir` 的同时配置 `mode = "strict"`。有数据目录而省略 mode 仍默认
snapshot；没有目录则为 off。off 配目录、strict 无目录或 strict 使用快照
定时参数均为配置错误。strict 的占盘设置如下：

```toml
[persistence]
mode = "strict"
data_dir = "/var/lib/moonbit-mqtt-broker"
wal_disk_max_bytes = 1073741824
wal_disk_reserve_bytes = 268435456
```

磁盘硬上限须比保留空间至少多一个 64 MiB 段。单事务 delta 默认最多
4 MiB，超出的持久结果在追加前拒绝；批次上限 64 个事务或 8 MiB，收集延迟
约 2 ms。每 60 秒尝试 checkpoint。详见[严格提交与恢复](persistence.zh_CN.md#strict-wal-模式)。

`--print-effective-config` 还会应用命令行覆盖，并以规范 TOML 输出最终配置；
私钥和密码文件的值会替换为 `<redacted>`。

## 在线配置热更新

热更新默认关闭。启动时使用绝对路径的 `--config` 和私有的版本 1
bundle manifest。manifest 列出有效配置及其引用的密码库、ACL、MQTT
TLS/WSS 证书与私钥的绝对路径和 SHA-256 摘要。完整发布材料和 manifest
后，再发 SIGHUP 或调用[配置管理热更新](management.zh_CN.md)。
`scripts/build-config-bundle.sh` 可生成不可变版本目录与 manifest，
四个参数依次是 `SOURCE_DIR VERSION_DIR CONFIG_TARGET MANIFEST_TARGET`；
目标路径必须与运行中 Broker 读取的路径一致。保留旧材料以便回滚和
strict 恢复。

```toml
[reload]
enabled = true
manifest_file = "/etc/moonbit-mqtt-broker/manifest.toml"
# 配置 MQTT TLS 或 WSS 监听器时必填。
material_runtime_dir = "/var/lib/moonbit-mqtt-broker/tls-material"
prepare_timeout_ms = 30000
max_source_bytes = 16777216
max_generation_bytes = 67108864
max_reconcile_items_per_turn = 64
max_reconcile_bytes_per_turn = 1048576
max_accounts = 4096
max_acl_rules = 4096
```

启用 reload 时要求 `max_pending_per_session <= 4096`，从而使每次
撤权清理复制和丢弃一条队列指针数组的工作量保持在固定单轮预算内。

材料运行目录必须是私有、可写的绝对路径，且与来源及持久化目录分开。
Broker 在准备候选前捕获并核验整个 bundle；无效或读取中变化的来源
不会替换现役代际。`--check-config` 可以校验配置的 bundle，不激活
配置，也不创建运行期 TLS 材料。CLI 覆盖在重新解析 TOML 时仍保持
启动时的优先级。

可热更新匿名开关、密码库、ACL、既有 MQTT TLS/WSS 证书与私钥内容、
日志级别/格式、系统指标周期和管理快照周期。其他有效标量、
监听拓扑/地址/传输、管理令牌及 reload 资源限制均需重启。
混合热字段与需重启字段的修改会整次拒绝；无变化请求不推进配置代际。
管理关闭时 SIGHUP 仍可用；HTTP 路由要求已启用管理监听器和
`config_admin` 令牌。旧 TLS 连接持有原材料 lease，新握手使用新代际。
详见[安全撤权](security.zh_CN.md#在线安全撤权)及
[持久化恢复](persistence.zh_CN.md#热更新与恢复)。

## 具名 MQTT 监听器与 WS/WSS

用 `[[listeners]]` 在同一 Broker 进程中同时启用 TCP、TLS、WS 和 WSS。
这种配置不能与旧的 `[server].listen` 或 `[tls]` 混用。未配置数组时，
旧单监听器继续使用 ID `mqtt`。最多 16 项；ID 必须唯一，长度 1–64，
只含 ASCII 字母、数字、`-`、`_`。`--once` 只接受一项。

```toml
[server]
max_connections = 128

[[listeners]]
id = "devices"
transport = "tcp"
listen = "127.0.0.1:1883"
max_connections = 128

[[listeners]]
id = "devices-tls"
transport = "tls"
listen = "0.0.0.0:8883"
max_connections = 96
tls_cert = "/etc/moonbit-mqtt-broker/server.crt"
tls_key = "/run/secrets/server.key"

[[listeners]]
id = "browser"
transport = "wss"
listen = "0.0.0.0:8084"
max_connections = 64
tls_cert = "/etc/moonbit-mqtt-broker/server.crt"
tls_key = "/run/secrets/server.key"
ws_path = "/mqtt"
ws_allowed_origins = ["https://dashboard.example.com"]
ws_require_origin = false
http_upgrade_timeout_ms = 5000
max_http_header_bytes = 16384
max_ws_frame_bytes = 1048576
max_ws_message_bytes = 4194304
```

所有入口共享 Broker 状态、Client ID、认证/ACL、持久化和全局
`max_connections`。单项上限不得超过全局上限，各项之和可以超过全局上限。
所有端口先完成绑定再开始接入；任一绑定失败会关闭已绑定端口。

WS/WSS 只在精确配置路径（默认 `/mqtt`）接受 HTTP/1.1 Upgrade，
要求 `mqtt` 子协议，并以二进制 WebSocket 帧承载 MQTT 字节；该端口
不提供管理 API。默认空 Origin 允许列表会拒绝带 Origin 的请求，
不带 Origin 的原生客户端可连接。浏览器页面需显式配置
`ws_allowed_origins`；`ws_require_origin = true` 要求所有客户端
都发送 Origin。Origin 不是 MQTT 身份验证；凭据仍由 MQTT CONNECT
和 ACL 处理，不要放在 URL 或子协议中。首版不协商压缩。

WS 需要 `libcrypto.so.3` 计算 RFC 6455 握手摘要，TLS/WSS 还需要
既有 TLS 运行库。启动时把 PEM 捕获到 0700 的私有
`/tmp/moonbit-mqtt-tls-*` 目录，副本文件为 0600；Broker 校验并用
该副本处理后续握手，正常退出时清理。运行环境需提供私有可写的
`/tmp`（运行容器使用 tmpfs）；持久宿主机上的进程被强杀后，运维
应清理该 Broker 用户拥有的遗留私有目录。监听器拓扑和 TLS 材料
变更需要重启。

`--check-config` 校验字段和 TLS 材料，但不绑定端口或创建私有副本。
有效配置摘要按输入顺序列出监听器并隐藏私钥路径，不能直接当作含
真实密钥的重启配置。

## 服务优雅退出

systemd 示例：

```ini
[Service]
ExecStart=/usr/local/bin/broker --config /etc/moonbit-mqtt-broker.toml
KillSignal=SIGTERM
TimeoutStopSec=30
Restart=on-failure
```

Docker 示例：

```bash
docker stop --signal=SIGTERM --time=30 moonbit-mqtt-broker
```

SIGTERM/SIGINT 会抑制活动连接的 Will 并写入最新快照。SIGKILL 只能保留
最近一次已提交的快照，不属于正常停止方式。


pending QoS 1/2 共用一套队列，规范键为 max_pending_per_session/total。
旧 max_pending_qos1_per_session/total 及 CLI flag 保留为别名；同一 TOML 或同次
CLI 同时使用新旧名称会报冲突，CLI 仍可覆盖 TOML。入站 QoS 2 使用独立上限：
每会话 0..65535（默认 64），全局非负（默认 4096）。这些条数限制与统一全局
字节账本、有界认证执行器同时生效。

密码校验默认使用 1 个原生 worker 和 16 个等待槽。queued/running 任务直到
原生完成都持有已验证 PHC 的 workspace 预留；队列或资源满时返回 MQTT 3.1.1
ServerUnavailable。轮询默认 5 ms、完成批次默认 16；关闭时即使超过 10000 ms
grace 观测点，也会继续 drain 原生任务，不提前释放其内存。


## 资源预算与限流

[完整计费与生命周期契约](resource-budgets.md)。字节是逻辑费用，不是 RSS 上限；现有条数限制同时生效。

```toml
[limits]
enabled = true
per_ip_enabled = true
```

两个开关的 CLI 名称分别为 `--rate-limits-enabled` 与 `--per-ip-limits-enabled`，取 true/false。NAT 后的客户端共享 IP 配额。数值 0 表示零容量或不补充 token，不表示无限制。

| TOML key | CLI | Default |
| --- | --- | --- |
| `resources.max_managed_bytes_total` | `--max-managed-bytes-total` | 268435456 |
| `resources.control_reserve_bytes` | `--control-reserve-bytes` | 2097152 |
| `broker.max_retained_bytes_total` | `--max-retained-bytes-total` | 16777216 |
| `broker.max_retained_message_bytes` | `--max-retained-message-bytes` | 1048576 |
| `broker.max_inflight_bytes_per_session` | `--max-inflight-bytes-per-session` | 4194304 |
| `broker.max_inflight_bytes_total` | `--max-inflight-bytes-total` | 33554432 |
| `broker.max_pending_bytes_per_session` | `--max-pending-bytes-per-session` | 8388608 |
| `broker.max_pending_bytes_total` | `--max-pending-bytes-total` | 67108864 |
| `broker.max_session_state_bytes` | `--max-session-state-bytes` | 12582912 |
| `broker.max_subscription_bytes_per_session` | `--max-subscription-bytes-per-session` | 131072 |
| `broker.max_subscription_bytes_total` | `--max-subscription-bytes-total` | 8388608 |
| `broker.max_session_metadata_bytes_total` | `--max-session-metadata-bytes-total` | 1048576 |
| `server.max_will_bytes_per_connection` | `--max-will-bytes-per-connection` | 1048576 |
| `server.max_will_bytes_total` | `--max-will-bytes-total` | 8388608 |
| `server.max_receive_bytes_total` | `--max-receive-bytes-total` | 16777216 |
| `server.max_runtime_bytes_per_connection` | `--max-runtime-bytes-per-connection` | 2097152 |
| `server.max_runtime_bytes_total` | `--max-runtime-bytes-total` | 16777216 |
| `server.max_outbound_bytes_per_connection` | `--max-outbound-bytes-per-connection` | 4194304 |
| `server.max_outbound_bytes_total` | `--max-outbound-bytes-total` | 33554432 |
| `server.max_connection_metadata_bytes_total` | `--max-connection-metadata-bytes-total` | 1048576 |
| `resources.max_limiter_metadata_bytes_total` | `--max-limiter-metadata-bytes-total` | 2097152 |
| `resources.max_routing_scratch_bytes` | `--max-routing-scratch-bytes` | 16777216 |
| `resources.max_snapshot_work_bytes` | `--max-snapshot-work-bytes` | 100663296 |
| `resources.max_auth_request_bytes_total` | `--max-auth-request-bytes-total` | 2097152 |
| `resources.max_auth_workspace_bytes_total` | `--max-auth-workspace-bytes-total` | 134217728 |
| `resources.max_auth_result_bytes_total` | `--max-auth-result-bytes-total` | 1048576 |
| `server.max_connections_per_ip` | `--max-connections-per-ip` | 32 |
| `limits.connect_rate_per_ip` | `--connect-rate-per-ip` | 10 |
| `limits.connect_burst_per_ip` | `--connect-burst-per-ip` | 20 |
| `limits.connect_rate_total` | `--connect-rate-total` | 100 |
| `limits.connect_burst_total` | `--connect-burst-total` | 200 |
| `limits.auth_rate_per_ip` | `--auth-rate-per-ip` | 5 |
| `limits.auth_burst_per_ip` | `--auth-burst-per-ip` | 10 |
| `limits.auth_rate_total` | `--auth-rate-total` | 20 |
| `limits.auth_burst_total` | `--auth-burst-total` | 40 |
| `limits.publish_messages_per_session` | `--publish-messages-per-session` | 100 |
| `limits.publish_messages_burst_per_session` | `--publish-messages-burst-per-session` | 200 |
| `limits.publish_bytes_per_session` | `--publish-bytes-per-session` | 1048576 |
| `limits.publish_bytes_burst_per_session` | `--publish-bytes-burst-per-session` | 2097152 |
| `limits.publish_messages_total` | `--publish-messages-total` | 5000 |
| `limits.publish_messages_burst_total` | `--publish-messages-burst-total` | 10000 |
| `limits.publish_bytes_total` | `--publish-bytes-total` | 16777216 |
| `limits.publish_bytes_burst_total` | `--publish-bytes-burst-total` | 33554432 |
| `limits.ingress_bytes_per_ip` | `--ingress-bytes-per-ip` | 4194304 |
| `limits.ingress_bytes_burst_per_ip` | `--ingress-bytes-burst-per-ip` | 8388608 |
| `limits.ingress_bytes_total` | `--ingress-bytes-total` | 33554432 |
| `limits.ingress_bytes_burst_total` | `--ingress-bytes-burst-total` | 67108864 |
| `limits.control_packets_per_connection` | `--control-packets-per-connection` | 1000 |
| `limits.control_packets_burst_per_connection` | `--control-packets-burst-per-connection` | 2000 |
| `limits.max_ip_buckets` | `--max-ip-buckets` | 4096 |
| `limits.idle_ttl_ms` | `--idle-ttl-ms` | 300000 |
| `server.max_runtime_events_per_connection` | `--max-runtime-events-per-connection` | 32 |

未显式配置的 retained 单消息与 Will 单连接上限跟随 max_packet_size。认证 workspace 按已验证 PHC 的 m（KiB）×1024 + p×256KiB + 1MiB 保守预留；这是逻辑预算，不是实测 RSS。快照超过新字节上限时启动失败，不裁剪旧状态。

## 管理端口

`[management]` 可选，默认关闭。令牌生成与路由语义见
[管理 API 指南](management.zh_CN.md)。CLI 名称是在同一键名前加
`--management-` 并把下划线换成连字符。例如
`[management] snapshot_max_age_ms` 对应
`--management-snapshot-max-age-ms`。CLI 优先于 TOML。

```toml
[management]
enabled = true
listen = "127.0.0.1:9091"
token_file = "/path/to/management-tokens"
max_connections = 16
max_header_bytes = 4096
max_header_count = 32
max_response_bytes = 65536
request_timeout_ms = 5000
write_timeout_ms = 2000
snapshot_interval_ms = 1000
snapshot_max_age_ms = 5000
ready_require_snapshot_healthy = false
request_rate = 50
request_burst = 100
connection_rate = 100
connection_burst = 200
max_bytes_total = 8388608
```

仅接受数字形式的 IPv4 loopback；主机名、非 loopback 地址及 IPv6
会被拒绝。启用时必须提供私有令牌文件，逻辑预算须容纳固定响应和请求
槽位。`--check-config` 可在绑定端口前校验文件及容量。

### 明细与操作配置

只读配置可省略下列键。启用明细和受保护操作时，显式设置
`details_enabled = true`、`operations_enabled = true` 及
`max_bytes_total = 33554432`。操作依赖明细，明细依赖管理端口。
`max_index_bytes` 须在启动时容纳 Broker 配置的最大对象数。CLI 参数均以
`--management-` 为前缀，键名中的下划线换成连字符。

| TOML 键 | 默认 | 范围 |
| --- | ---: | --- |
| `details_enabled` | false | 布尔值 |
| `operations_enabled` | false | 布尔值，依赖明细 |
| `query_queue_limit` | 16 | 1..64 |
| `operation_queue_limit` | 16 | 1..64 |
| `max_operation_records` | 256 | 16..4096 |
| `max_running_operations` | 8 | 1..min(32, records) |
| `operation_timeout_ms` | 30000 | 1000..120000 |
| `operation_retention_ms` | 900000 | 1000..3600000 |
| `max_cursor_records` | 256 | 16..4096 |
| `cursor_ttl_ms` | 60000 | 1000..300000 |
| `default_page_size` | 50 | 1..max_page_size |
| `max_page_size` | 100 | 1..500 |
| `query_scan_limit` | 256 | max_page_size..2048 |
| `query_timeout_ms` | 2000 | 启用明细时为 100..request_timeout_ms |
| `max_audit_records` | 1024 | 64..16384 |
| `command_rate` | 5 | 每秒 1..1000 |
| `command_burst` | 10 | 1..2000 |
| `max_index_bytes` | 8388608 | 正数；启用明细时不大于 max_bytes_total |

MQTT accept 前，父池会预留固定的索引、查询、游标，以及启用操作后的
Operation、命令和审计容量。逻辑索引费用为每最大 Session 256 字节、
每 MQTT 连接 192、每最大订阅 192、每最大 retained 条目 128。默认
容量（1024、128、16384、1024）需要 3,563,520 字节。
`max_index_bytes` 不足会使启动失败，不会暗中降低 MQTT 限额。
运行时完成与分页语义见[管理 API](management.zh_CN.md)。
