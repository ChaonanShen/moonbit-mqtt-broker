# Compatibility and support matrix

| Capability | Current status | Notes |
| --- | --- | --- |
| Linux x86_64 Native build | Supported | Pinned Docker and CI path |
| MQTT 3.1.1 CONNECT / CONNACK | Supported | Full clean/persistent `session_present` semantics |
| TCP split/sticky packet framing | Supported | Capacity-aware reader plus bounded three-state decoder |
| Equal packet/receive limits | Supported | 16/16 boundary covers complete CONNECT plus sticky PINGREQ |
| Packet codec for QoS 0/1 families | Supported | Complete-frame adapter; Packet ID/DUP combinations gated |
| MQTT.js 5.15.2 interoperability | Supported for M4 | QoS 0/1, retained/Will, persistent Session and multi-process restart |
| Mosquitto 2.0.18 interoperability | Supported for M4 | QoS 0/1, retained and persistent offline restart delivery |
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
| Snapshot V1 data boundary | Supported | Deterministic pure import/export reused by Disk V1 |
| State across Broker restart | Supported when `--data-dir` is set | Debounced local snapshot to latest committed revision |
| QoS 2 / MQTT 5 | Unsupported | Explicitly rejected / out of scope |
| TLS / WebSocket / auth / ACL | Unsupported | Out of first-release scope |

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
