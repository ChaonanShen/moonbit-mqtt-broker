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

[observability]
system_metrics_interval_ms = 10000
log_format = "json"
log_level = "info"
```

`--check-config` 会验证 TOML 及其引用的 TLS/安全文件，但不会监听端口、
获取持久化锁、打开持久化文件或创建数据目录。

`--print-effective-config` 还会应用命令行覆盖，并以规范 TOML 输出最终配置；
私钥和密码文件的值会替换为 `<redacted>`。

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
每会话 0..65535（默认 64），全局非负（默认 4096）。这些是条数上限；统一全局
字节账本和认证 worker 隔离属于独立后续工作。


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
