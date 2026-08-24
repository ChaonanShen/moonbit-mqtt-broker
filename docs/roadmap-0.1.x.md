# MQTT Broker 0.1.x execution roadmap

This roadmap extends the completed M0-M5 MQTT 3.1.1 QoS 0/1 release candidate.
Work is deliberately split into independently reviewable milestones. Every
change must retain the cumulative M5 release gate and add tests before or with
the implementation.

## Release boundary

The recommended `0.1.0` boundary is M6-M8:

- M6: deterministic graceful shutdown and final snapshot commit;
- M7: optional single-listener TLS;
- M8: static authentication, topic ACLs, persistent-Session ownership, and
  Snapshot V2 backward-compatible recovery.

M9-M11 remain single-node features and may ship in `0.1.1` if they would delay
the first release:

- M9: persistent-Session expiration;
- M10: `$SYS` metrics and structured logs;
- M11: TOML configuration, documentation, packaging, and final hardening.

MQTT 5, QoS 2, clustering, Bridge, WebSocket, plugins, and a management UI are
not part of this roadmap.

## Progress

- [x] M6 graceful SIGTERM/SIGINT shutdown, final Snapshot drain, active-Will
  suppression, process integration tests, and cumulative verifier.
- [x] M7 optional TLS transport, startup credential/key-permission validation,
  bounded handshakes, restart recovery, MQTT.js/Mosquitto interoperability,
  rejection, concurrency, and cumulative verifier.
- [x] M8 authentication, ACLs, Principal ownership, and Snapshot V2.
- [x] M9 persistent-Session expiration.
- [x] M10 `$SYS` metrics and structured logs.
- [x] M11 TOML configuration and final hardening.

## Working rules

1. Add a failing or characterization test before changing behavior.
2. Keep each commit and pull request focused on one observable contract.
3. Preserve plain MQTT 3.1.1 compatibility unless a security option is
   explicitly enabled.
4. Reject invalid or incomplete configuration before binding a listener.
5. Never log credentials, private keys, ACL contents, or application payloads.
6. Keep Router, Session, Topic, and Security policy code deterministic and free
   of socket/filesystem ownership.
7. Run targeted tests first, then the cumulative verifier before closing a
   milestone.

## M6: graceful shutdown and final snapshot

### Contract

On SIGTERM or SIGINT the Broker stops accepting new connections, terminates
active connections with `ServerShutdown`, suppresses their Wills, detaches
persistent Sessions, removes clean Sessions, forces the newest Snapshot, waits
for the SnapshotWriter, releases the data-directory lock, and exits within a
bounded time. SIGKILL retains only the existing latest-committed guarantee.

### Steps

1. Add a process-level integration test with a debounce long enough that the
   test state cannot be committed by the timer before SIGTERM.
2. Seed retained state, a persistent subscription, offline QoS 1, and an active
   Will; signal the Broker and restart it.
3. Prove the latest retained/Session state survived and the shutdown Will did
   not fire.
4. Repeat for SIGINT and for persistence disabled.
5. If characterization fails, add a `RuntimeEvent::Shutdown`, reject later
   opens/packets, dispatch `CloseTransport(ServerShutdown)`, close the listener
   and event queue in order, then call `force_snapshot()` and protect the writer
   wait from cancellation.
6. Add concise start/commit/complete shutdown logs without secrets.

### Acceptance

- SIGTERM and SIGINT exit within five seconds in the integration profile.
- The final revision is restored on restart.
- Server shutdown never publishes a client Will.
- Shutdown and close paths are idempotent.
- All M0-M5 gates continue to pass.

## M7: optional TLS transport

### Scope

Add a mutually exclusive plain or TLS mode for the existing single listener.
Do not add simultaneous listeners, mTLS, SNI routing, or certificate reload in
the first implementation.

### Configuration

```text
--tls-cert PATH
--tls-key PATH
--tls-handshake-timeout-ms 10000
```

Both credential options are required together. Credential paths and formats
are validated before accepting clients. The private key must be a regular file
with safe permissions.

### Steps

1. Refactor `ConnectionSupervisor` to depend on a small Reader/Writer/Close
   transport boundary instead of concrete MQTT framing over `Tcp`.
2. Preserve the plain-TCP implementation as one transport.
3. Wrap accepted TCP connections with `moonbitlang/async/tls` in TLS mode.
4. Count handshaking sockets against `max_connections` and bound handshake
   time.
5. Keep TLS failures isolated from healthy clients and out of BrokerRuntime.
6. Add MQTT.js and Mosquitto TLS interoperability tests for QoS 0/1, retained,
   persistent Sessions, restart recovery, invalid CA, plaintext-on-TLS, invalid
   credentials, timeout, and concurrent connections.

### Acceptance

- Plain mode remains byte-for-byte compatible.
- TLS mode passes MQTT.js and Mosquitto interoperability.
- A failed/slow handshake cannot block the listener or Router.
- Keys and test credentials are excluded from release packages.

## M8: authentication, ACLs, and Session ownership

### Security model

Add a pure `src/security` package with `Principal`, authentication result,
read/write access, password-file parsing, ACL parsing, and topic authorization.
The initial principals are `Anonymous` and `User(username)`.

### Configuration

```text
--allow-anonymous true|false
--password-file PATH
--acl-file PATH
```

Security files are parsed completely before listen. Live reload, external
identity providers, and plugins are deferred.

### Password decision gate

Use a maintained Argon2id implementation if available. A reviewed native
`libargon2` boundary or a versioned established KDF is acceptable after a
separate dependency and packaging review. Do not invent a password hash, store
plaintext passwords, compare secrets with an early-exit loop, or pass passwords
on the command line.

### Protocol behavior

- Authenticate before Session lookup or mutation.
- Bad credentials return `BadUsernameOrPassword`; an authenticated but
  unauthorized connection returns `NotAuthorized`.
- Authentication failure sends a rejecting CONNACK, closes, and never fires a
  Will.
- Validate Will write access during CONNECT.
- A denied SUBSCRIBE entry returns `0x80` without failing allowed entries.
- Read ACLs are checked both when accepting a filter and when delivering a
  concrete topic.
- A denied QoS 0 publish is dropped and audited.
- A denied QoS 1 publish is acknowledged but not routed or retained, avoiding
  a retry loop; this policy must be documented.
- Client writes to `$SYS/#` are always denied.

### ACL format

The first format has allow-only rules and default deny:

```text
user sensor01
topic write devices/sensor01/data
topic read devices/sensor01/command/#
```

Implement and exhaustively test filter containment. A broad requested filter is
not allowed merely because some of its concrete topics would be readable.

### Persistent Session ownership and Snapshot V2

Bind every authenticated persistent Session to its Principal. A different
Principal using the same Client ID cannot resume, delete, or take over that
Session. Add `owner_principal` and `detached_at_ms` together in Snapshot V2 so
M9 does not require another immediate disk migration.

The decoder must continue reading Snapshot/Disk V1. Legacy Sessions become
`LegacyAnonymous` and are resumable only under an explicitly documented
anonymous migration policy. Writers emit V2 after upgrade. Never silently give
a legacy Session to the first authenticated user.

### Acceptance

Tests cover valid/invalid credentials, anonymous policy, partial SUBACK denial,
publish/retained/Will ACLs, `$SYS`, wildcard containment, malformed and special
security files, Principal-safe takeover, cross-user Client-ID attacks, V1-to-V2
recovery, restart ownership, and absence of secrets in logs and packages.

## M9: persistent-Session expiration

### Configuration and behavior

```text
--persistent-session-expiry never
--persistent-session-expiry 30d
--max-session-expirations-per-tick 128
```

Default to `never` for compatibility. Store epoch `detached_at_ms` in Snapshot
V2. Only detached persistent Sessions expire; active Sessions do not. Expiration
removes subscriptions, inflight and pending QoS 1, updates global counters, and
advances the snapshot revision. A clock rollback delays rather than accelerates
expiration and emits a warning.

Tests cover exact boundaries, reconnect reset, active Sessions, restart,
bounded sweeps, counter recovery, and persistence of deletion.

## M10: `$SYS` metrics and structured logs

### Metrics

Publish version, uptime, connected clients, Sessions, subscriptions, retained,
QoS 1 inflight/pending, received/sent/dropped messages, authentication failures,
ACL denials, TLS handshake failures, and persistence state under `$SYS/broker`.

System metrics use a separate internal path: they do not consume retained
capacity, enter snapshots, count themselves, or accept client writes. Explicit
`$SYS` subscriptions and read ACLs still apply.

### Logs

Support text and JSON plus error/warn/info/debug levels. Standard fields include
timestamp, event, connection ID, Client ID, Principal, peer, reason, and
snapshot revision. Redact credentials, keys, ACL contents, and payloads.

Tests cover stable field names, redaction, counter accuracy, `$SYS` isolation,
ACLs, and no metric feedback loop.

## M11: TOML configuration and release hardening

Add `--config`, side-effect-free `--check-config`, and redacted
`--print-effective-config`. Precedence is CLI over TOML over built-in defaults.
Unknown and duplicate keys are fatal. Use a maintained TOML parser; do not ship
a partial home-grown parser.

Update README, compatibility, architecture, persistence, testing, release, and
new security/configuration documentation. Include a complete TLS/auth example,
Snapshot V1-to-V2 migration and rollback notes, systemd/Docker shutdown examples,
and the limitations of plaintext MQTT credentials.

## Pull-request sequence

1. M6 shutdown characterization tests.
2. M6 shutdown state machine and logs, if required.
3. M7 generic transport boundary.
4. M7 TLS mode and interoperability.
5. M8 Security types and credential decision/implementation.
6. M8 ACL parser and authorization paths.
7. M8 Principal ownership and Snapshot V2 migration.
8. M9 Session expiration.
9. M10 metrics, then logging.
10. M11 TOML, documentation, and release audit.

## Final release gate

Each milestone adds a cumulative verifier. Before release, run the complete
gate three consecutive times and the extended soak once. It must include
plain/TLS MQTT.js and Mosquitto, V1-to-V2 fixtures, negative auth/ACL and Client
ID takeover cases, at least twenty SIGTERM final-snapshot cycles, 100 TLS
clients, the existing bounded workloads, clean-room package reconstruction,
secret/artifact scanning, and a clean Git worktree.
