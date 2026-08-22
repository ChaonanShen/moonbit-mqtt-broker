# Porting scope and provenance

M1's topic matching, subscription indexing, retained-message handling, and pure
event/action state machine, M2's connection runtime, bounded driver, TCP
supervisor, Will/Keep Alive/takeover behavior, and M3's Packet ID, QoS 1,
persistent Session, offline queue, and Snapshot V1 implementation are original
MoonBit code guided by MQTT 3.1.1 semantics. No Aedes source or test code was
copied.

The fixed primary reference is Aedes `v1.1.1`, commit
`eac44f9920b49dd20eb0e83cc9d5c4b9038eb963` (MIT). M0 does not copy or adapt
Aedes Broker, Client, Router, or handler source; it only freezes the future
responsibility boundary described in the project plans. M2 follows the general
Broker/Client/handler responsibility split but does not translate a specific
Aedes file, function, or test. Future direct adaptation must still record its
file-level source here.

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
specification and errata. M3 implements QoS 0/1 routing, PUBACK/inflight,
Retained, QoS 0/1 Will, clean and persistent Session lifecycle, Keep Alive,
takeover, offline QoS 1, reconnect DUP replay, and a pure Snapshot V1 boundary.
It does not implement snapshot files or process-restart restoration,
authentication, plugins, bridges, or clustering.
