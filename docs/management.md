# Read-only management API

[中文](management.zh_CN.md) | **English**

The optional management listener serves process health, a bounded Prometheus
scrape, and a status summary. It is disabled by default and accepts only
`127.0.0.1:PORT`. It is a separate HTTP/1.1 listener from MQTT and TLS. The
current release has no management write, query, reload, or online token-rotation
endpoint.

## Start

Create a 32-byte random secret and store only its domain-separated SHA-256
digest in a private regular file:

```bash
secret="$(openssl rand -hex 32)"
token="observer.${secret}"
digest="$(printf 'moonbit-mqtt-broker/admin/v1:%s' "${token}" | sha256sum | awk '{print $1}')"
printf 'observer:%s:metrics,read\n' "${digest}" >management-tokens
chmod 0600 management-tokens
printf 'Client bearer token: %s\n' "${token}"
```

Keep the printed token in your secret manager. The Broker requires the file to
be owned by its runtime user and readable only by that user. It rejects
symlinks, directories, FIFOs, permissive modes, malformed records, duplicate
IDs, and files over 16 KiB. The client token is
`token_id.64_lowercase_hex_secret`; roles are explicit and do not include
each other. Up to 32 entries are accepted.

```bash
broker --management-enabled true \
  --management-listen 127.0.0.1:9091 \
  --management-token-file /path/to/management-tokens
```

`--check-config` validates the token source before serving. The enabled
listener dynamically loads `libcrypto.so.3`; disabled management does not
require that library for its own feature. The supported Ubuntu 24.04 runtime
images include libcrypto. Changing the token file requires a restart.

## Routes

| Route | Authentication | Response |
| --- | --- | --- |
| `GET /health/live` | None | 200 when the process is live; 503 when it can respond but is unavailable |
| `GET /health/ready` | None | 200 when MQTT and management are ready and the observation is fresh; otherwise 503 |
| `GET /metrics` | Bearer token with `metrics` role | Prometheus text 0.0.4; 503 on stale observation |
| `GET /v1/status` | Bearer token with `read` role | Bounded JSON summary; 503 on stale observation |

```bash
curl -H "Authorization: Bearer ${token}" http://127.0.0.1:9091/metrics
curl -H "Authorization: Bearer ${token}" http://127.0.0.1:9091/v1/status
```

Missing or invalid credentials receive 401; insufficient scope receives 403.
Tokens in a query string, cookie, or request body are ignored. The API
accepts one bounded GET request per connection. It rejects ambiguous headers,
request bodies, suffix requests, and unsupported methods. Health routes are
anonymous but still subject to the listener's connection and request limits.

The status response contains a boot ID, observation time and age, lifecycle,
readiness, MQTT counts, persistence summary, and resource usage. Int64 values
are decimal strings in JSON. It does not expose client IDs, topics, payloads,
token material, file paths, or principals. Metrics use fixed names and labels;
the set is capped at 256 series. The `publish_actions_total` counter counts
downstream actions, not confirmed socket writes. Scrapes do not create MQTT
publications or change MQTT receive counters.

## Readiness and limits

The routing loop publishes a cached observation on its own schedule. A fresh
heartbeat is needed for readiness; a stale cache makes readiness, metrics and
status unavailable. A degraded snapshot makes readiness fail only when
`ready_require_snapshot_healthy` is enabled. The liveness route can remain
available while readiness is false. An event loop that cannot run may result
in a client timeout instead of an HTTP 503.

Defaults: 16 management connections, 4 KiB header, 32 headers, 64 KiB
response, 5 s request deadline, 2 s write deadline, 1 s observation interval,
5 s maximum observation age, and an 8 MiB logical management budget.
Independent request and connection token buckets default to 50/s with burst
100 and 100/s with burst 200. See [configuration](configuration.md) for CLI
and TOML keys and [resource budgets](resource-budgets.md) for accounting.

The listener is loopback HTTP without its own TLS. Restrict who can access the
host/network namespace and use a secure channel if you forward it. Do not put
the bearer token in command logs or URLs. Prometheus needs a
`bearer_token_file` containing the client token. The
[release runbook](release-verification.md) verifies an authorized scrape and a
wrong-token failure against the packaged runtime.
