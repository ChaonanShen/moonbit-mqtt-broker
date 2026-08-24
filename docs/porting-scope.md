# Porting scope and provenance

M1's topic matching, subscription indexing, retained-message handling, and pure
event/action state machine, M2's connection runtime, bounded driver, TCP
supervisor, Will/Keep Alive/takeover behavior, and M3's Packet ID, QoS 1,
persistent Session, offline queue, and Snapshot V1 implementation, plus M4's
Disk V1 codec, locked atomic store, revision scheduler, and restart wiring are
original MoonBit code guided by MQTT 3.1.1 and POSIX durability semantics. No
Aedes source or test code was copied.

The fixed primary reference is Aedes `v1.1.1`, commit
`eac44f9920b49dd20eb0e83cc9d5c4b9038eb963` (MIT). M0 does not copy or adapt
Aedes Broker, Client, Router, or handler source; it only freezes the future
responsibility boundary described in the project plans. M2 follows the general
Broker/Client/handler responsibility split but does not translate a specific
Aedes file, function, or test. Future direct adaptation must still record its
file-level source here.

The M5 adopted-case map is behavioral only:

| Aedes baseline area | Local automated scenario | Use and difference |
| --- | --- | --- |
| CONNECT / client lifecycle | `m5_protocol_matrix.mjs` clean and duplicate CONNECT | Behavior observed; no source copied |
| subscription handling | SUBACK order, wildcard, empty level, overlap | Behavior observed; MQTT specification wins on overlap maximum QoS |
| publish / retained handlers | live QoS 0/1 and retained replay/delete | Behavior observed; no handler code copied |
| client Will lifecycle | forced close and graceful DISCONNECT | Behavior observed; no test code copied |
| persistent client state | M3/M4 Session, offline FIFO, DUP restart gates | Architecture consulted; MoonBit model/tests are original |

M0 directly depends on `moonbitlang/async@0.20.6` and
`zbhzs1/moonbit-mqtt@0.1.0`, both Apache-2.0. Candidate codec types remain
inside a conversion adapter. Adapter pre-validation and error classification
are original code in this repository.

`mqtt-packet@9.0.2` (MIT) is a development-only behavioral oracle. The
repository calls its public packet generator/parser to create deterministic
wire fixtures; no JavaScript implementation source is copied or linked into
the Broker. MQTT.js and Mosquitto are interoperability clients, not source
ports.

The normative protocol reference is the OASIS MQTT Version 3.1.1 final
specification and errata. M4 implements QoS 0/1 routing, PUBACK/inflight,
Retained, QoS 0/1 Will, clean and persistent Session lifecycle, Keep Alive,
takeover, offline QoS 1, reconnect DUP replay, a pure Snapshot V1 boundary, and
opt-in local process-restart snapshots. It does not implement WAL, synchronous
per-ack persistence, authentication, plugins, bridges, or clustering.
