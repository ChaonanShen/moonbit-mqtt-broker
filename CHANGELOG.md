# Changelog

## M4 - 2026-08-24

- Added deterministic checksummed Disk Snapshot V1 with strict UTF-8,
  count/length preflight, resource limits, and byte-stable golden coverage.
- Added canonical data directories, process-lifetime exclusive locks, bounded
  regular-file recovery, stale-temp deletion, and fatal corrupt-main policy.
- Added same-directory `0600` temp writes, full file sync, atomic replace rename,
  directory sync, and failure-injection proof that pre-rename failures preserve
  the previous main snapshot.
- Added export-visible Broker revisions, quiet debounce/max-delay scheduling,
  capacity-one latest-wins submission, async single-writer retry/recovery, and
  natural-shutdown drain.
- Added `--data-dir` and snapshot tuning CLI flags with recovery-before-listen
  startup ordering and explicit classified logs.
- Added MQTT.js three-process restart, 20-session capacity, raw inflight
  Packet-ID/DUP, Mosquitto restart, stale-temp/crash, special-file, permission,
  and corrupt-main gates plus the reproducible M4 Docker verifier.

## M3 - 2026-08-22

- Added inbound and outbound MQTT 3.1.1 QoS 1 with same-ID PUBACK, per-Session
  Packet ID allocation, ordered inflight ownership, and pending FIFO promotion.
- Added `clean_session=false`, complete `session_present` behavior, persistent
  subscriptions, bounded offline QoS 1, and original-ID `DUP=1` reconnect replay.
- Added QoS 1 Will routing/Retained behavior and clean/persistent takeover,
  disconnect, stale-generation, and resource-exhaustion semantics.
- Added per-Session and total Session/inflight/pending limits with atomic
  client-publication failure and isolated no-origin resource drops.
- Added deterministic, versioned Snapshot V1 pure import/export with complete
  validation, alias isolation, and restored-state injection before accept.
- Added raw TCP, MQTT.js, and Mosquitto QoS 1/persistent-session gates plus the
  reproducible M3 Docker verifier.

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
- Expanded the M2 acceptance gate with 58 server test blocks covering the full
  Will close-reason matrix, stale generations, protocol-error Will, retained
  deletion, slow consumers, supervisor first-terminal-wins, capacity-one event
  queues, and exact/overflow packet boundaries.
- Added deterministic reader/writer failure classification, simultaneous
  reader/writer/closer termination, Queue-close wakeup, and healthy-client
  isolation coverage for transport I/O failures.

## M0 - 2026-08-21

- Pinned the Linux x86_64 Native MoonBit build and test environment.
- Verified TCP, bounded Queue, Timer, cancellation, and TaskGroup behavior.
- Froze project-owned MQTT Packet, CodecError, and FrameDecoder boundaries.
- Passed the candidate codec gate and selected `moonbit-mqtt@0.1.0`.
- Added the minimal real TCP MQTT 3.1.1 CONNECT → CONNACK service.
- Added shared Docker/CI verification, compatibility, provenance, and support
  documentation.
