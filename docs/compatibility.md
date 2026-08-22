# Compatibility and support matrix

| Capability | Current status | Notes |
| --- | --- | --- |
| Linux x86_64 Native build | Supported | Pinned Docker and CI path |
| MQTT 3.1.1 CONNECT / CONNACK | Supported | Accepted CONNACK, `session_present=false` |
| TCP split/sticky packet framing | Supported | Bounded three-state decoder |
| Packet codec for planned QoS 0/1 families | Gated | Complete-frame adapter; M2 serves QoS 0 only |
| MQTT.js 5.15.2 interoperability | Supported for M2 | QoS 0 pub/sub, retained, Will, takeover |
| Mosquitto 2.0.18 interoperability | Supported for M2 | QoS 0 pub/sub and retained replay |
| Topic validation and PUBLISH/SUBSCRIBE routing | Supported | `+`, `#`, `$SYS`, overlap merge, deterministic order |
| Keep Alive and PING | Supported | 1.5× deadline; zero disables idle timeout |
| Client ID takeover | Supported | Connection-generation stale event isolation |
| Retained delivery | Supported | Live `RETAIN=0`, replay `RETAIN=1`, empty payload deletes |
| QoS 0 Will | Supported | EOF, I/O/protocol failure, timeout, and takeover; DISCONNECT suppresses |
| Network SUBACK / UNSUBACK | Supported | Input Packet ID and subscription order preserved |
| Empty Client ID | Supported with clean session | Unique internal process-local ID |
| QoS 1 PUBACK / inflight | Not implemented | Planned for M3 |
| `clean_session=false` | Explicitly rejected | `IdentifierRejected` for empty ID, otherwise `ServerUnavailable` |
| QoS 1 Will | Explicitly rejected | `ServerUnavailable`; never downgraded to QoS 0 |
| Persistent Session | Not implemented | Planned for M3; `session_present` is always false |
| State across Broker restart | Not implemented | Planned for M4 |
| QoS 2 / MQTT 5 | Unsupported | Explicitly rejected / out of scope |
| TLS / WebSocket / auth / ACL | Unsupported | Out of first-release scope |

CONNECT must be the first packet. Malformed frames, oversize declarations,
direction errors, duplicate CONNECT, inbound QoS 1 PUBLISH/PUBACK, or other
unsupported flows close the connection. An inbound QoS 1 PUBLISH is rejected
before routing or retained storage and receives no PUBACK.
