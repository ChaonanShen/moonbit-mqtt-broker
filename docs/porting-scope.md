# Porting scope and provenance

The fixed primary reference is Aedes `v1.1.1`, commit
`eac44f9920b49dd20eb0e83cc9d5c4b9038eb963` (MIT). M0 does not copy or adapt
Aedes Broker, Client, Router, or handler source; it only freezes the future
responsibility boundary described in the project plans. Those components start
in M1/M2 and must record any file-level reference when introduced.

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
specification and errata. M0 implements no Router, Retained, Session, inflight,
Will delivery, persistence, authentication, plugin, bridge, or cluster logic.
