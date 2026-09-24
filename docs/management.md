# Management API

[中文](management.zh_CN.md) | **English**

The optional listener is loopback HTTP/1.1 at `127.0.0.1:PORT`. Health,
Prometheus, and status work when management is enabled. Detail queries and
operations have separate switches and are disabled by default. MQTT continues
to run if a derived detail index becomes unavailable; detail and write routes
then return 503 until restart. This API has no HTTPS, remote bind, UI, message
payload view, bulk deletion, retained deletion, token rotation, or live reload.

## Start and roles

The token file contains a SHA-256 digest, never a plaintext bearer token.
Create a 32-byte secret and protect the file as the runtime user:

```bash
secret="$(openssl rand -hex 32)"
token="operator.$secret"
digest="$(printf 'moonbit-mqtt-broker/admin/v1:%s' "$token" | sha256sum | awk '{print $1}')"
printf 'operator:%s:read,operator\n' "$digest" >management-tokens
chmod 0600 management-tokens
```

Tokens have the form `token_id.64_lowercase_hex_secret`. A token can carry
`metrics`, `read`, `operator`, and/or `config_admin`. Scopes do not imply one
another: an operator needs an explicit `read` scope to discover targets.
`GET /v1/operations/{id}` and `GET /v1/audit` require `operator` or
`config_admin` and reveal only records issued by the same token ID. Token
material, raw request headers, payloads, and passwords never enter responses
or audit records. The file must be a private regular file owned by the runtime
user. Replacing it requires a restart.

```toml
[management]
enabled = true
listen = "127.0.0.1:9091"
token_file = "/path/to/management-tokens"
details_enabled = true
operations_enabled = true
max_bytes_total = 33554432
```

`operations_enabled` requires `details_enabled`, which requires `enabled`.
The 32 MiB example is explicit; A-only deployments retain the 8 MiB default.
The same parent quota charges request, cache, index, query, cursor, Operation,
and audit reservations and remains subject to the ordinary Broker ledger.
`--check-config` rejects invalid sizes, dependencies, or token files before
binding. See [configuration](configuration.md) and
[resource budgets](resource-budgets.md).

## Routes

| Route | Scope | Result |
| --- | --- | --- |
| `GET /health/live`, `GET /health/ready` | none | Health, 200 or 503 |
| `GET /metrics` | metrics | Bounded Prometheus text |
| `GET /v1/status` | read | Observation, capabilities and availability |
| `GET /v1/listeners` | read | Current MQTT TCP and management HTTP listener |
| `GET /v1/connections[/{id}]` | read | Volatile connection phase, client/principal if known, ETag |
| `GET /v1/sessions[/{handle}]` | read | Session identity, lifecycle, ownership and queue counts/bytes |
| `GET /v1/sessions/{handle}/subscriptions` | read | Filter and QoS, no payload |
| `GET /v1/retained` | read | Topic, QoS and payload byte count, no payload |
| `GET /v1/config` | read | Whitelisted limits and switches, no token path or secrets |
| `POST /v1/connections/{id}/disconnect` | operator | Close that connection; abnormal Will rules apply |
| `DELETE /v1/sessions/{handle}` | operator | Delete only an offline persistent Session |
| `GET /v1/operations/{id}` | operator or config_admin | Own in-process Operation |
| `GET /v1/audit` | operator or config_admin | Own recent in-process audit events |
| `POST /v1/config/reload` | config_admin | 202 for an accepted reload when enabled; 503 `reload_disabled` when disabled |

A connection begins at `await_connect`, may enter `authenticating`, and then
`active`. TLS handshakes before MQTT registration are not listed. Named TCP/TLS/WS/WSS MQTT listeners share the same Broker state; the
management listener is separate and does not count as an MQTT connection.

The status persistence object reports `mode`, `state`, `committed_lsn`,
`applied_lsn`, `checkpoint_lsn`, pending WAL transactions/bytes, and the
snapshot fields. Int64 values are decimal strings. In strict mode a fenced or
recovering state forces `ready=false` regardless of the snapshot-only health
switch; read-only status and metrics remain available while the event loop is
healthy. Prometheus exposes bounded WAL LSN/pending gauges without Client ID,
topic or file labels.

## Details and pagination

Lists accept `limit` (default 50, maximum 100) and `cursor`. Sessions also
accept `attached=true|false` and `mode=clean|persistent`; connections accept
`phase=await_connect|authenticating|active`. Unknown, duplicate, or malformed
query fields are rejected. IDs in paths must be canonical positive decimal
strings. Client IDs, topics, and filters appear only in escaped JSON values;
they cannot be put into a path to address a Session.

List responses contain `api_version`, `boot_id`, decimal-string
`observed_at_ms` and `state_revision`, `consistency:"per_page"`, `items`, and
`next_cursor` (string or null). A page scans at most 256 physical slots by
default; sparse filters can return an empty `items` array with a cursor.
Cursor handles are random, bound to the token ID, route, filters, boot and
index generation, and expire after 60 seconds without retry extension. The
default table holds 256 cursors. A cursor is not a snapshot: new or deleted
rows in unscanned slots may change later pages, and a new object in an already
scanned slot may be omitted. A live instance does not move slots during a
traversal. No ordering across independent traversals is promised.

The default body limit is 64 KiB. Rows are not silently truncated. If one
escaped row cannot fit, the route returns 422 `result_too_large`; increase
`max_response_bytes` in a reviewed configuration and restart. If more rows
would overflow a page, it returns the rows that fit and a cursor for the
unread row. Querying retained metadata never copies a retained payload.

A Session `handle` identifies an instance only within one boot. It changes
when a clean or persistent Session is replaced or recreated. A persistent
reconnect keeps the handle but advances `lifecycle_version`; successful
attach and detach advance it too. Pending messages, ACKs and byte-budget
changes do not advance this lifecycle version. An offline delete removes
whatever belongs to that instance at the serialized execution point,
including messages added after the detail read.

## Commands and completion

Read the current detail and copy its `connection_etag` or `etag` into one
strong `If-Match` header. Add an `Idempotency-Key` of 16–64 ASCII letters,
digits, `_` or `-`. Weak ETags, `*`, lists, duplicate headers, URL aliases and
any request body are rejected. A new valid command returns HTTP 202 with a
`Location: /v1/operations/{id}` header and an Operation record. The HTTP
response can be lost while the accepted command continues; query the
Operation or retry with the same key. The same token ID/key and identical
method, target and ETag return the original Operation (202 while active,
200 after terminal). The same key with a different request returns 409.
Terminal records and their idempotency keys remain for 15 minutes by default;
running records are never evicted by that TTL. IDs and keys do not survive a
restart, so this is not cross-restart exactly-once execution.

A kick targets a numeric ConnectionId, never a Client ID. It signals the
transport, waits for the real terminal/unregister and all associated
authentication tasks to be reaped, then succeeds. A prior valid MQTT
DISCONNECT suppresses the Will; otherwise kick follows abnormal-close Will
rules, at most once. A later connection using the same Client ID is not the
target. `timed_out=true` means the deadline elapsed; a started kick continues
supervision until its effect is known or shutdown records uncertainty.

Delete rechecks the handle, lifecycle ETag and offline persistent state on the
single writer, releases all Session queues, QoS 2 and subscriptions, and
dispatches capacity released to other sessions. It does not delete retained
messages or publish a historical Will. To remove an online Session: kick,
wait for its Operation to succeed, fetch the new offline ETag, then delete.
A stale lifecycle ETag returns 412; an online target returns 409.

In `off` and `snapshot`, writes report `completion_scope:"runtime"`;
`snapshot_committed_revision_at_finish` is only an observation, and a SIGKILL
before the next snapshot can restore an older Session. In `strict`, delete
succeeds only after its WAL transaction is synced and applied. Kick also waits
for the durable detach/cleanup and any triggered Will successor transaction.
Terminal strict records report `persistence_mode:"strict"`,
`completion_scope:"durable"`, and decimal `committed_lsn_at_finish`. Accepted
and running Operation records remain process-local; a lost HTTP response or
crash can still leave the caller uncertain and must be reconciled on restart.

## Audit and limits

The audit endpoint returns own events with `sequence`,
`oldest_available_sequence`, `audit_overwritten_total`, `gap` and an opaque
continuation cursor. Accepted, started and terminal events contain fixed codes
and opaque IDs. The fixed in-memory ring overwrites its oldest entry when
full. Reads do not create audit events. Audit is not durable: restart loses it;
collect it externally if retention matters. Existing Broker logs may still
block on their configured stdout sink; the management audit ring adds no
per-request synchronous log write.

Common errors are 401 invalid/missing token, 403 wrong scope, 428 missing
command preconditions, 400 malformed input, 404 missing target or another
token's Operation, 409 active Session or idempotency conflict, 410 expired
cursor or previous-boot Operation, 412 stale ETag, 422 oversized row, 429
capacity/rate exhaustion, 501 unavailable reload, and 503 disabled, degraded
or stopping facility. All responses use `Cache-Control: no-store`. The
listener has independent connection, request and command token buckets and
fixed queue/slot caps; slow readers hold their request slot through the
actual write. It is loopback HTTP without its own TLS. Restrict local access
and use a secure channel if forwarding it.
