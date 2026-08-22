# Changelog

## M2 - 2026-08-22

- Added a deterministic BrokerRuntime and bounded RouterDriver with unique
  connection generations and stale-event isolation.
- Added multi-client async TCP supervision, streaming decode, ordered writers,
  handshake/Keep Alive timeouts, and slow-consumer isolation.
- Added network QoS 0 publish/subscribe, SUBACK/UNSUBACK, Retained, QoS 0 Will,
  empty Client IDs, and Client ID takeover.
- Added validated M2 resource/CLI configuration, 10,000-event and concurrent
  loopback regressions, and MQTT.js/Mosquitto interoperability gates.
- Explicitly reject persistent sessions, QoS 1 Publish/PUBACK, and QoS 1 Will
  until M3 instead of silently downgrading them.
- Fixed equal packet/receive-buffer handling so a complete packet can be
  drained before an adjacent sticky packet is read.
- Expanded the M2 acceptance gate with 55 server test blocks covering the full
  Will close-reason matrix, stale generations, protocol-error Will, retained
  deletion, slow consumers, supervisor first-terminal-wins, capacity-one event
  queues, and exact/overflow packet boundaries.

## M0 - 2026-08-21

- Pinned the Linux x86_64 Native MoonBit build and test environment.
- Verified TCP, bounded Queue, Timer, cancellation, and TaskGroup behavior.
- Froze project-owned MQTT Packet, CodecError, and FrameDecoder boundaries.
- Passed the candidate codec gate and selected `moonbit-mqtt@0.1.0`.
- Added the minimal real TCP MQTT 3.1.1 CONNECT → CONNACK service.
- Added shared Docker/CI verification, compatibility, provenance, and support
  documentation.
