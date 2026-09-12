# Configuration

[中文](configuration.zh_CN.md) | **English**

Precedence is CLI over TOML over built-in defaults. The Broker uses maintained
`bobzhang/toml`; malformed TOML, duplicate keys, unknown sections/keys, and
wrong types are fatal.

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

`--check-config` validates TOML and referenced TLS/security files without
binding, locking, opening persistence, or creating the data directory.
`--print-effective-config` also applies CLI overrides and prints canonical TOML
with private-key/password-file values replaced by `<redacted>`.

## Graceful service shutdown

```ini
[Service]
ExecStart=/usr/local/bin/broker --config /etc/moonbit-mqtt-broker.toml
KillSignal=SIGTERM
TimeoutStopSec=30
Restart=on-failure
```

```bash
docker stop --signal=SIGTERM --time=30 moonbit-mqtt-broker
```

SIGTERM/SIGINT suppress active Wills and drain the newest snapshot. SIGKILL
retains only the latest committed snapshot and is not a normal stop mechanism.

Pending QoS 1/2 share one queue: max_pending_per_session/total are the canonical
keys. The old max_pending_qos1_per_session/total keys and CLI flags remain aliases.
Using both names in one TOML file or one CLI invocation is an error; CLI still
overrides TOML. Inbound QoS 2 has independent per-session (0..65535, default 64)
and global (nonnegative, default 4096) limits. These count limits apply together
with the global byte ledger and the bounded authentication executor.

Password verification uses one native worker and 16 waiting slots by default.
Queued and running jobs retain their validated PHC workspace reservation until
native completion; queue/resource exhaustion returns MQTT 3.1.1 ServerUnavailable.
The poll interval defaults to 5 ms, completion batches to 16, and shutdown keeps
draining native work after the 10000 ms grace observation point.


## Byte budgets and rate admission

See the [accounting and ownership contract](resource-budgets.md). Bytes are logical quotas, not RSS limits; existing count limits also apply.

```toml
[limits]
enabled = true
per_ip_enabled = true
```

The CLI switches are `--rate-limits-enabled` and `--per-ip-limits-enabled`, accepting true/false. NAT clients share an IP quota. Numeric zero means zero capacity or no refill, never unlimited.

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

Unless explicitly configured, retained-message and per-connection Will limits follow max_packet_size. Authentication conservatively reserves validated PHC m (KiB) ×1024 + p×256KiB +1MiB; this is logical budgeting, not measured RSS. Restore exceeding a byte cap fails startup instead of truncating old state.
