# Compatibility and support matrix

[中文](compatibility.zh_CN.md) | **English**

| Capability | Current status | Notes |
| --- | --- | --- |
| Linux x86_64 Native build | Supported | Pinned Docker and CI path |
| MQTT 3.1.1 CONNECT / CONNACK | Supported | Full clean/persistent `session_present` semantics |
| TCP split/sticky packet framing | Supported | Capacity-aware reader plus bounded three-state decoder |
| Equal packet/receive limits | Supported | 16/16 boundary covers complete CONNECT plus sticky PINGREQ |
| Packet codec for QoS 0/1 families | Supported | Complete-frame adapter; Packet ID/DUP combinations gated |
| MQTT.js 5.15.2 interoperability | Supported for 0.1.0 | QoS 0/1, retained/Will, persistent Session and multi-process restart |
| Mosquitto 2.0.18 interoperability | Supported for 0.1.0 | QoS 0/1, retained and persistent offline restart delivery |
| Aedes 1.1.1 reference matrix | Test-only | Normalized common behavior; no runtime dependency or plugin compatibility claim |
| Topic validation and PUBLISH/SUBSCRIBE routing | Supported | `+`, `#`, `$SYS`, overlap merge, deterministic order |
| Keep Alive and PING | Supported | 1.5× deadline; zero disables idle timeout |
| Client ID takeover | Supported | Connection-generation stale event isolation |
| Retained delivery | Supported | Live `RETAIN=0`, replay `RETAIN=1`, empty payload deletes |
| QoS 0/1 Will | Supported | EOF, I/O/protocol failure, timeout, and takeover; DISCONNECT suppresses |
| Network SUBACK / UNSUBACK | Supported | Input Packet ID and subscription order preserved |
| Empty Client ID | Supported with clean session | Unique internal process-local ID |
| QoS 1 PUBACK / inflight | Supported | Same-ID inbound PUBACK; per-Session outbound IDs and ordered inflight |
| `clean_session=false` | Supported with nonempty Client ID | Empty ID is `IdentifierRejected` |
| Persistent Session | Supported across connections | Subscriptions, inflight and bounded offline QoS 1 survive reconnect |
| Reconnect DUP replay | Supported | Existing inflight keeps original Packet ID and sets `DUP=1` |
| Snapshot V2 data boundary | Supported | Principal and detach epoch; reads legacy V1 and rewrites V2 |
| State across Broker restart | Supported when `--data-dir` is set | Debounced local snapshot to latest committed revision |
| SIGTERM / SIGINT shutdown | Supported | Stops normally, suppresses active Wills, forces and drains latest Snapshot |
| TLS listener | Supported, opt-in | TLS-only single listener; PEM startup validation and bounded handshakes |
| MQTT.js/Mosquitto over TLS | Supported for 0.1.0 | QoS 0/1, retained, persistent Session and restart recovery |
| Argon2id authentication | Supported, opt-in | Encoded hashes only; anonymous allowed by default |
| Static allow-only ACL | Supported, opt-in | Read/write filters, partial SUBACK, `$SYS` client-write denial |
| Principal-owned Client IDs | Supported | Cross-Principal takeover/clean/resume rejected across restart |
| Persistent Session expiry | Supported, opt-in | Default never; active Sessions excluded; bounded deterministic sweeps |
| `$SYS/broker` metrics | Supported | Explicit subscription/read ACL; QoS 0, non-retained, not persisted/counted |
| Text/JSON structured logs | Supported | error/warn/info/debug with stable fields and secret/payload redaction |
| TOML configuration | Supported | CLI > TOML > defaults; unknown/duplicate keys fatal; check/print modes |
| QoS 2 / MQTT 5 | Unsupported | Explicitly rejected / out of scope |
| WebSocket | Unsupported | Out of current release scope |
| Shared subscriptions / Bridge / plugins / cluster | Unsupported | Single-node Broker only |
| External database / WAL / zero-loss durability | Unsupported | Latest-committed local snapshot only |

CONNECT must be the first packet. Malformed frames, oversize declarations,
direction errors, duplicate CONNECT, QoS 2, or other unsupported flows close
the connection. A client-origin QoS 1 publication that exceeds Session
inflight/pending resources is rejected atomically without PUBACK so the client
can retry according to its Session lifecycle. QoS 1 Will/internal publication
drops only saturated recipients and continues routing to healthy recipients.

The receive-buffer limit applies to undecoded buffered bytes. Exact-limit
packets, partial prefixes followed by sticky suffixes, and multiple pipelined
control packets are covered over real TCP. Declared oversize and malformed
packets continue to close before unbounded buffering.

The Broker does not perform periodic retransmission on an otherwise connected network.
Unacknowledged outbound QoS 1 is retransmitted when a persistent Session is
resumed. With persistence enabled, retained messages, persistent subscriptions,
inflight/pending QoS 1, original Packet IDs, and the next Packet ID survive a
Broker restart. Clean Sessions, QoS 0 offline messages, connections, Keep Alive
timers, and Wills that have not yet fired are not persisted.

This is not a fully durable or zero-loss Broker. Changes inside the debounce
window may be lost on crash; recovery is to the most recent successfully
committed snapshot. A corrupt main snapshot prevents startup rather than being
ignored or replaced by stale temp data.

Release verification compares a normalized common matrix against Mosquitto 2.0.18 and Aedes
1.1.1. Mosquitto may choose QoS 0 when one client has overlapping QoS 0 and
QoS 1 subscriptions; MQTT 3.1.1 section 3.3.5 requires the maximum QoS of all
matching subscriptions. The MoonBit exact matrix therefore continues to
require one QoS 1 delivery, while the differential matrix compares delivery
count and payload for that reference-deviation case. Aedes is a behavioral
reference only, and no Aedes source is linked into the Broker.

TLS uses the pinned `moonbitlang/async@0.20.6` OpenSSL-backed Native transport.
The listener is either plaintext or TLS, never both. mTLS, SNI routing,
certificate reload, multiple listeners, and Windows TLS are not claimed.
The dependency currently marks its server-side TLS constructors experimental;
this release pins the exact version and validates startup, rejection,
interoperability, concurrency, shutdown, and restart behavior in CI.

The supported `$SYS/broker` set includes version, uptime, connected clients,
Sessions, subscriptions, retained, QoS 1 inflight/pending, received/sent/dropped
messages, authentication failures, ACL denials, TLS handshake failures, and
persistence state. A bare `#` subscription does not match `$SYS` per MQTT 3.1.1.
