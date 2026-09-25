# Configuration

[中文](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/configuration.zh_CN.md) | **English**

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

`--check-config` validates TOML and referenced TLS/security files without
binding, locking, opening persistence, or creating the data directory.
For synchronous WAL durability, set `mode = "strict"` with `data_dir`. Omitting
`mode` preserves the snapshot default when a directory is supplied; without a
directory the mode is `off`. Explicit `off` with `data_dir`, strict without
`data_dir`, and strict with snapshot timing knobs are errors. Strict accepts:

```toml
[persistence]
mode = "strict"
data_dir = "/var/lib/moonbit-mqtt-broker"
wal_disk_max_bytes = 1073741824
wal_disk_reserve_bytes = 268435456
```

The disk maximum must exceed the reserve by at least one 64 MiB segment.
The default WAL transaction encoding cap is 4 MiB; an oversized persistent
result is refused before append. The batch cap is 64 transactions or 8 MiB,
with an approximately 2 ms collection delay. Checkpoints are attempted every
60 seconds. See [strict commit and recovery](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/persistence.md#strict-wal-mode).
`--print-effective-config` also applies CLI overrides and prints canonical TOML
with private-key/password-file values replaced by `<redacted>`.

## Live configuration reload

Reload is disabled by default. Start with an absolute `--config` path and an
absolute, private version 1 bundle manifest. The manifest lists the effective
config and every referenced password, ACL, and MQTT TLS/WSS certificate/key
file, each with its absolute path and SHA-256 digest. Publish the complete
material set and manifest before sending SIGHUP or requesting a
[config-admin reload](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/management.md). `scripts/build-config-bundle.sh`
stages an immutable version directory and manifest; its four arguments are
`SOURCE_DIR VERSION_DIR CONFIG_TARGET MANIFEST_TARGET`. The target paths must
match the paths the running Broker reads. Keep prior material available for
rollback and strict recovery.

```toml
[reload]
enabled = true
manifest_file = "/etc/moonbit-mqtt-broker/manifest.toml"
# Required when any MQTT TLS or WSS listener is configured.
material_runtime_dir = "/var/lib/moonbit-mqtt-broker/tls-material"
prepare_timeout_ms = 30000
max_source_bytes = 16777216
max_generation_bytes = 67108864
max_reconcile_items_per_turn = 64
max_reconcile_bytes_per_turn = 1048576
max_accounts = 4096
max_acl_rules = 4096
```

Reload requires `max_pending_per_session <= 4096` so revocation can
copy and discard one queued pointer array within its fixed per-turn budget.

The material runtime directory must be a private, writable absolute path
outside the source and persistence directories. The Broker captures a checked
bundle before preparing a candidate; an invalid or changed source leaves the
active generation intact. `--check-config` validates a configured bundle
without activating it or creating runtime TLS material. CLI overrides keep
their startup precedence when a new TOML bundle is evaluated.

Hot fields are the anonymous setting, password and ACL files, existing
MQTT TLS/WSS certificate/key bytes, log level/format, system metrics interval,
and management snapshot timing. All other effective scalar settings,
listener topology/address/transport, management tokens and reload limits
require restart. A mixed hot and restart-only edit is rejected as a whole.
A no-change request does not advance the config epoch. SIGHUP works with
management disabled; the HTTP route requires an enabled management listener
and a `config_admin` token. Existing TLS connections retain their material
lease while new handshakes use the new generation. See
[security revocation](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/security.md#live-security-revocation) and
[persistence recovery](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/persistence.md#reload-and-recovery).

## Named MQTT listeners and WS/WSS

Use `[[listeners]]` to bind TCP, TLS, WS and WSS in one Broker process. This
form replaces the legacy `[server].listen` and `[tls]` settings; mixing them
is rejected. Without `[[listeners]]`, the legacy single listener keeps its
`mqtt` ID. At most 16 listeners are accepted. IDs must be unique, 1–64 ASCII
letters, digits, `-` or `_`. `--once` accepts exactly one listener.

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

All entries share the one Broker state, Client ID space, security policy,
persistence and global `max_connections`. Each listener's cap cannot exceed
the global cap. The caps need not sum to the global cap. All sockets are bound
before any begins accepting; a bind failure closes those already bound.

WS/WSS accepts only HTTP/1.1 Upgrade on the exact configured path (default
`/mqtt`), requires the `mqtt` subprotocol, and carries MQTT bytes in binary
WebSocket frames. It does not serve management routes. The default empty
Origin allowlist rejects requests with an Origin header; native clients without
Origin may connect. Set `ws_allowed_origins` for browser pages and
`ws_require_origin = true` if every client must send one. Origin filtering
does not replace MQTT CONNECT authentication. Compression is not negotiated.
Do not put credentials in the URL or WebSocket subprotocol.

WS requires `libcrypto.so.3` for the RFC 6455 handshake digest. TLS/WSS also
requires the existing TLS runtime libraries. At startup, TLS PEM files are
copied into a private `/tmp/moonbit-mqtt-tls-*` directory with mode 0700
and private 0600 files. The Broker validates and uses those captured copies
for new handshakes, then removes them on normal shutdown. Provide a private
writable `/tmp` (the runtime container uses tmpfs); after a forced process
kill on a persistent host `/tmp`, an operator should remove stale private
directories owned by that Broker user. Listener topology and TLS material
changes require a restart.

`--check-config` validates listener fields and referenced TLS material
without binding or creating the private generation. The effective config
summary prints listeners in input order and redacts private-key paths; it is
not a directly restartable secret-bearing config.

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

In snapshot mode, SIGTERM/SIGINT suppress active Wills and drain the newest
snapshot; SIGKILL retains only the latest committed snapshot. In strict mode,
normal shutdown drains accepted WAL mutations and durable detach operations;
SIGKILL recovery replays complete committed batches.

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

See the [accounting and ownership contract](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/resource-budgets.md). Bytes are logical quotas, not RSS limits; existing count limits also apply.

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

## Management listener

`[management]` is optional and disabled by default. See the
[management API guide](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/management.md) for token generation and route behavior.
CLI switches use the same key with a `--management-` prefix and hyphens.
For example, `[management] snapshot_max_age_ms` maps to
`--management-snapshot-max-age-ms`. CLI overrides TOML.

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

Only numeric IPv4 loopback is accepted; hostnames, non-loopback addresses and
IPv6 are rejected. Enabling management requires a private token file and a
logical budget large enough for the required fixed responses and request
slots. `--check-config` validates the file and capacity without binding.

### Detail and operation settings

A read-only A configuration can omit all keys below. To expose detail
queries and protected writes, set `details_enabled = true`,
`operations_enabled = true` and an explicit `max_bytes_total = 33554432`.
`operations_enabled` requires details, and details require management.
`max_index_bytes` must cover the configured Broker object capacities at
startup. All CLI flags use the `--management-` prefix and hyphenated key name.

| TOML key | Default | Valid range |
| --- | ---: | --- |
| `details_enabled` | false | boolean |
| `operations_enabled` | false | boolean; requires details |
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
| `query_timeout_ms` | 2000 | 100..request_timeout_ms when details are enabled |
| `max_audit_records` | 1024 | 64..16384 |
| `command_rate` | 5 | 1..1000 per second |
| `command_burst` | 10 | 1..2000 |
| `max_index_bytes` | 8388608 | positive, no more than max_bytes_total when details are enabled |

The parent pool reserves fixed index/query/cursor and, when operations are on,
Operation/command/audit capacity before MQTT accepts. The logical index fee
is 256 bytes per maximum Session, 192 per MQTT connection, 192 per maximum
subscription and 128 per maximum retained entry. The default capacities
(1024, 128, 16384, 1024) require 3,563,520 bytes. A smaller
`max_index_bytes` fails startup; it does not silently reduce MQTT limits.
See [management API](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/management.md) for the runtime completion and pagination
contracts.
