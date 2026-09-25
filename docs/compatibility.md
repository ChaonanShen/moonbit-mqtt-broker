# Compatibility and support matrix

[中文](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/compatibility.zh_CN.md) | **English**

| Capability | Current status | Notes |
| --- | --- | --- |
| Linux x86_64 Native build | Supported | Pinned Docker and CI path |
| Optional loopback management HTTP | Supported | Anonymous live/ready; scoped Bearer metrics/status, bounded reads and kick/delete Operations; optional config-admin reload |
| MQTT 3.1.1 CONNECT / CONNACK | Supported | Full clean/persistent `session_present` semantics |
| TCP split/sticky packet framing | Supported | Capacity-aware reader plus bounded three-state decoder |
| Equal packet/receive limits | Supported | 16/16 boundary covers complete CONNECT plus sticky PINGREQ |
| Packet codec for QoS 0/1/2 families | Supported | Complete-frame adapter; Packet ID/DUP combinations gated |
| MQTT.js 5.15.2 interoperability | Supported | QoS 0/1/2, retained/Will, persistent Session and multi-process restart |
| Mosquitto 2.0.18 interoperability | Supported | QoS 0/1/2, retained and persistent offline restart delivery |
| Aedes 1.1.1 reference matrix | Test-only | Normalized common behavior; no runtime dependency or plugin compatibility claim |
| Topic validation and PUBLISH/SUBSCRIBE routing | Supported | `+`, `#`, `$SYS`, overlap merge, deterministic order |
| Keep Alive and PING | Supported | 1.5× deadline; zero disables idle timeout |
| Client ID takeover | Supported | Connection-generation stale event isolation |
| Retained delivery | Supported | Live `RETAIN=0`, replay `RETAIN=1`, empty payload deletes |
| QoS 0/1/2 Will | Supported | EOF, I/O/protocol failure, timeout, and takeover; DISCONNECT suppresses |
| Network SUBACK / UNSUBACK | Supported | Input Packet ID and subscription order preserved |
| Empty Client ID | Supported with clean session | Unique internal process-local ID |
| QoS 1 PUBACK / inflight | Supported | Same-ID inbound PUBACK; per-Session outbound IDs and ordered inflight |
| `clean_session=false` | Supported with nonempty Client ID | Empty ID is `IdentifierRejected` |
| Persistent Session | Supported across connections | Subscriptions, inflight and bounded offline QoS 1/2 survive reconnect |
| Reconnect DUP replay | Supported | Original IDs; PUBLISH with DUP=1 or PUBREL 0x62 by phase |
| Snapshot V3 data boundary | Supported | Inbound IDs and outbound phases; reads legacy V1/V2 and writes V3 |
| State across Broker restart | Supported when `--data-dir` is set | Snapshot defaults to latest committed revision; explicit strict WAL replays complete committed LSNs |
| SIGTERM / SIGINT shutdown | Supported | Suppresses active Wills; snapshot drains final revision, strict drains accepted WAL and detach work |
| TLS listener | Supported, opt-in | Shared multi-listener Broker; private startup PEM snapshot and bounded handshakes |
| MQTT.js/Mosquitto over TLS | Supported | QoS 0/1/2, retained, persistent Session and restart recovery |
| Argon2id authentication | Supported, opt-in | Encoded hashes only; anonymous allowed by default |
| Bounded authentication executor | Supported | Native worker/queue limits, timeout and cancellation-safe cleanup |
| Resource and rate admission | Supported, enabled by default | Logical byte budgets plus connection/authentication/publish policies |
| Static allow-only ACL | Supported, opt-in | Read/write filters, partial SUBACK, `$SYS` client-write denial |
| Principal-owned Client IDs | Supported | Cross-Principal takeover/clean/resume rejected across restart |
| Persistent Session expiry | Supported, opt-in | Default never; active Sessions excluded; bounded deterministic sweeps |
| `$SYS/broker` metrics | Supported | Explicit subscription/read ACL; QoS 0, non-retained, not persisted/counted |
| Text/JSON structured logs | Supported | error/warn/info/debug with stable fields and secret/payload redaction |
| TOML configuration | Supported | CLI > TOML > defaults; unknown/duplicate keys fatal; check/print modes |
| QoS 2 | Supported | Method B inbound deduplication, bounded state, phase-aware reconnect and V3 recovery |
| MQTT 5 | Unsupported | Out of scope |
| WebSocket / WSS | Supported, opt-in | Binary MQTT frames, mqtt subprotocol, Origin allowlist and bounded Upgrade |
| Shared subscriptions / Bridge / plugins / cluster | Unsupported | Single-node Broker only |
| Live configuration reload | Supported, opt-in | Verified bundle; SIGHUP or config-admin; passwords, ACLs, TLS/WSS and supported runtime fields; disabled by default |
| Strict local WAL | Supported, opt-in | Commit-before-ACK for defined persistent state; fenced on uncertain write, no replication |
| External database / cluster / end-to-end zero-loss | Unsupported | Single-node storage and MQTT exchange boundary only |

CONNECT must be the first packet. Malformed frames, oversize declarations,
direction errors, duplicate CONNECT, or other unsupported flows close
the connection. A client-origin QoS 1/2 publication that exceeds Session
inflight/pending resources is rejected atomically without PUBACK/PUBREC so the client
can retry according to its Session lifecycle. QoS 1/2 Will/internal publication
drops only saturated recipients and continues routing to healthy recipients.

The receive-buffer limit applies to undecoded buffered bytes. Exact-limit
packets, partial prefixes followed by sticky suffixes, and multiple pipelined
control packets are covered over real TCP. Declared oversize and malformed
packets continue to close before unbounded buffering.

The Broker does not perform periodic retransmission on an otherwise connected network.
Unacknowledged outbound QoS 1/2 is retransmitted when a persistent Session is
resumed. With persistence enabled, retained messages, persistent subscriptions,
inflight/pending QoS 1/2, inbound QoS 2 IDs, original Packet IDs, and the next Packet ID survive a
Broker restart. Clean Sessions, QoS 0 offline messages, connections, Keep Alive
timers, and Wills that have not yet fired are not persisted.

Snapshot mode can lose debounce-window changes after a crash and restores the
latest committed snapshot. Strict mode restores complete WAL commits before
releasing the corresponding persistent-state ACKs; an unacknowledged commit
may also replay. Neither mode replicates data or guarantees end-to-end business
processing. Corrupt authoritative snapshot/WAL files fail startup closed.

Release verification compares a normalized common matrix against Mosquitto 2.0.18 and Aedes
1.1.1. Mosquitto may choose QoS 0 when one client has overlapping QoS 0 and
QoS 1 subscriptions; MQTT 3.1.1 section 3.3.5 requires the maximum QoS of all
matching subscriptions. The MoonBit exact matrix therefore continues to
require one QoS 1 delivery, while the differential matrix compares delivery
count and payload for that reference-deviation case. Aedes is a behavioral
reference only, and no Aedes source is linked into the Broker.

TLS uses the pinned `moonbitlang/async@0.20.6` OpenSSL-backed Native transport.
Each listener selects TCP, TLS, WS or WSS; all entries share one Broker state.
mTLS, SNI routing and Windows TLS are not claimed. Existing TLS/WSS certificate material can rotate through a verified reload bundle.
The dependency currently marks its server-side TLS constructors experimental;
this release pins the exact version and validates startup, rejection,
interoperability, concurrency, shutdown, and restart behavior in CI.

The supported `$SYS/broker` set includes version, uptime, connected clients,
Sessions, subscriptions, retained, QoS 1 inflight/pending, received/sent/dropped
messages, authentication failures, ACL denials, TLS handshake failures, and
persistence state. A bare `#` subscription does not match `$SYS` per MQTT 3.1.1.

## QoS 2 exchange boundary

The first accepted QoS 2 PUBLISH commits inbound Packet ID metadata, routing and
retained effects in one single-writer event (MQTT 3.1.1 Method B). A duplicate
uncompleted ID only receives PUBREC, even if DUP is clear or payload differs.
PUBREL removes that record and receives PUBCOMP; an unknown PUBREL also receives
PUBCOMP. ACL-denied publications use the same bounded handshake without routing.

Outbound QoS 1/2 share Packet IDs and inflight capacity. PUBREC releases the
QoS 2 topic/payload while retaining an AwaitPubcomp slot. PUBCOMP releases the ID
and promotes pending FIFO messages. Persistent reconnect sends CONNACK first,
replays PUBLISH with original ID and DUP=1, and replays AwaitPubcomp as PUBREL
with fixed header 0x62. Unknown PUBREC receives stateless PUBREL; confirmations
for an existing but incompatible phase close the connection.

The guarantee applies to each MQTT exchange. Downstream QoS 1 can still repeat.
In snapshot mode PUBREC/PUBCOMP do not imply fsync. In strict mode their
persistent-state changes are WAL committed first. Neither mode promises
end-to-end exactly-once or protection against loss of the storage device.

Metrics qos/inflight and qos/pending count QoS 1/2; legacy qos1 names remain aliases.
qos2/inbound, qos2/await_pubrec and qos2/await_pubcomp report held state.
qos2/received counts admitted PUBLISH packets including duplicates; qos2/duplicates
counts dedup responses, and qos2/rejected counts resource rejections.
