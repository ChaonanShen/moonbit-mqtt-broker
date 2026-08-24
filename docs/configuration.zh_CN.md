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
max_pending_qos1_per_session = 64
max_pending_qos1_total = 1024
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

