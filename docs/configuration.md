# Configuration

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
