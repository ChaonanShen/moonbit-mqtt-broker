# Compatibility and support matrix

| Capability | M0 status | Notes |
| --- | --- | --- |
| Linux x86_64 Native build | Supported | Pinned Docker and CI path |
| MQTT 3.1.1 CONNECT / CONNACK | Supported | Accepted CONNACK, `session_present=false` |
| TCP split/sticky packet framing | Supported | Bounded three-state decoder |
| Packet codec for planned QoS 0/1 families | Gated | Complete-frame API; not all flows are served yet |
| MQTT.js 5.15.2 client CONNECT | Supported | MQTT protocol level 4 smoke-tested |
| Mosquitto 2.0.18 client CONNECT | Supported | Accepted CONNACK smoke-tested |
| Topic validation and pure PUBLISH/SUBSCRIBE routing | Supported in Router core | Deterministic, transport-free M1 state machine |
| Keep Alive / takeover / full connection state | Not implemented | Planned for M2 |
| Retained delivery | Supported in Router core | Bounded retained store; network delivery awaits M2 |
| Network PUBLISH/SUBSCRIBE / SUBACK / UNSUBACK | Not implemented | Planned for M2 transport integration |
| QoS 1 PUBACK / inflight | Not implemented | Planned for M3 |
| Persistent Session | Not implemented | Planned for M3 |
| State across Broker restart | Not implemented | Planned for M4 |
| QoS 2 / MQTT 5 | Unsupported | Explicitly rejected / out of scope |
| TLS / WebSocket / auth / ACL | Unsupported | Out of first-release scope |

The M0 server requires CONNECT as the first packet. Malformed frames, codec
errors, oversize declarations, direction errors, or unsupported subsequent
flows cause connection closure.
