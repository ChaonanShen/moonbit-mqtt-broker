# Changelog

All notable user-visible changes are documented here.

## [Unreleased]

## [0.3.0]

- Add multiple TCP, TLS, WS and WSS listeners sharing one Broker state, with bounded WebSocket upgrade and Origin policy.
- Add loopback management detail, scoped kick/offline Session deletion, bounded audit and config-admin operations.
- Add opt-in verified-bundle live reload through SIGHUP or config-admin, including password/ACL revocation and existing TLS/WSS material rotation.
- Add opt-in strict local WAL durability with fsync-gated MQTT acknowledgements,
  QoS 1/2 and persistent Session recovery, bounded group commits, checkpoint
  rotation and fail-closed recovery/fencing. Snapshot remains the default with
  a data directory.
- Make management delete and kick completion durable in strict mode, with
  committed LSN diagnostics and read-only access after a durability fence.
- Verify strict behavior through all four MQTT transports, snapshot migration,
  held-fsync/crash recovery, four isolated library profiles and optional soak;
  provide a fixed-disk paired performance runner.

## [0.2.0] - 2026-09-13

- Implement MQTT 3.1.1 QoS 2 in both directions: duplicate handling, persistent
  reconnect, retained/Will, bounded inbound state and shared QoS 1/2 pending limits.
- Write Snapshot/Disk V3 with inbound IDs and outbound phases while retaining
  strict V1/V2 readers.
- Add unified logical byte budgets for sessions, routing, transport, snapshots and
  authentication, plus default-enabled global/per-IP connection, authentication
  and publish admission limits.
- Run Argon2id verification on a bounded native worker executor with PHC cost
  validation, queue saturation handling, timeouts, cancellation-safe cleanup and
  bounded operational metrics so expensive password checks do not block routing.
- Expand release verification with QoS 2 recovery and interoperability, resource
  saturation, authentication isolation, sanitizer coverage, four minimal runtime
  profiles, an optional ten-minute soak and reproducible artifact hashes.
- Preserve latest-committed snapshot durability; acknowledgements do not imply fsync.

### Upgrade notes

- Stop the old broker and back up its complete data directory before upgrading.
  After version 0.2.0 writes a V3 snapshot, version 0.1.0 cannot read it; rollback
  requires restoring the pre-upgrade backup.
- Connection, authentication and publish rate policies are enabled by default.
  Review the documented limits before upgrading high-volume or NAT-heavy deployments.

## [0.1.0] - 2026-08-24

- Released a single-node MQTT 3.1.1 TCP/TLS broker for Linux x86_64 Native
  with QoS 0/1, wildcard routing, retained messages, QoS 0/1 Wills, Keep Alive,
  Client ID takeover, persistent Sessions, bounded offline QoS 1, and reconnect
  replay with the original Packet ID and `DUP=1`.
- Added optional checksummed Disk/Snapshot V2 latest-committed persistence,
  strict V1 migration, exclusive data-directory locking, atomic replacement,
  bounded retry, and state recovery before the listener opens.
- Added graceful SIGTERM/SIGINT shutdown that suppresses active Wills, forces
  the newest snapshot, and drains the persistence writer before exit.
- Added optional Argon2id authentication, allow-only ACLs, Principal-owned
  Client IDs, persistent-Session expiry, and a TLS-only listener mode.
- Added `$SYS/broker/#` metrics, redacted text/JSON logs, TOML configuration,
  side-effect-free configuration validation, and CLI-over-file precedence.
- Added executable examples, MQTT.js/Mosquitto interoperability tests, Aedes
  behavioral comparison, bounded stability workloads, CI, secret scanning,
  documentation checks, and clean-room mooncakes package verification.
- Pinned MoonBit `0.10.10+f8a486b6f` for reproducible release validation.
- Known limitations: no MQTT 5, QoS 2, WebSocket, shared subscriptions,
  bridges, plugins, clustering, external databases, WAL, or zero-loss
  durability.
