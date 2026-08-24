# Changelog

All notable user-visible changes are documented here.

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
