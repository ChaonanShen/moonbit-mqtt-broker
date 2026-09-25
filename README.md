# moonbit-mqtt-broker

[中文](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/README.zh_CN.md) | **English**

[![CI](https://github.com/ChaonanShen/moonbit-mqtt-broker/actions/workflows/ci.yml/badge.svg)](https://github.com/ChaonanShen/moonbit-mqtt-broker/actions/workflows/ci.yml)

A lightweight, single-node MQTT 3.1.1 broker implemented in MoonBit.

Version `0.3.0` targets Linux x86_64 Native for small deployments,
local development, interoperability testing, and MoonBit MQTT applications. It
supports TCP, TLS, WS or WSS clients, QoS 0/1/2, wildcard subscriptions, retained
messages, Wills, Keep Alive, persistent Sessions, optional restart persistence,
authentication, ACLs, metrics, structured logs, and TOML configuration.

The optional [management API](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/management.md) provides loopback health,
scoped Prometheus metrics, bounded detail queries, and protected connection
kick/offline Session deletion. Detail and write routes have separate switches
and are disabled by default. The listener uses a private token file.

## What is new in 0.3.0

- Add opt-in strict local WAL durability for defined persistent MQTT state, with commit-before-ACK recovery and fail-closed fencing.
- Add multiple TCP, TLS, WS and WSS listeners sharing one Broker state.
- Add bounded management detail, kick and offline Session deletion operations, plus protected configuration administration.
- Add opt-in live configuration reload for verified password, ACL, TLS/WSS and supported runtime settings. Reload is disabled by default.

Before upgrading a persistent deployment, read the [V3 migration and rollback notes](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/persistence.md) and review the [default resource and rate limits](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/configuration.md).

## Quick start

The reproducible path uses Docker and does not require a host MoonBit install:

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 0.0.0.0:1883
```

In another terminal, publish and subscribe with any MQTT 3.1.1 client:

```bash
mosquitto_sub -h 127.0.0.1 -p 1883 -t 'demo/#' -q 1
mosquitto_pub -h 127.0.0.1 -p 1883 -t demo/hello -m world -q 1
```

For a guided setup, configuration file, persistence, and production-oriented
security example, read the [getting-started guide](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/getting-started.md).

## Features

| Area | Current source |
| --- | --- |
| Protocol | MQTT 3.1.1 over TCP, TLS, WS or WSS |
| Delivery | QoS 0/1/2 publish/subscribe; phase-aware PUBLISH/PUBREL replay |
| Topics | `+` and `#` filters, deterministic overlap merge, retained messages |
| Sessions | Clean and persistent Sessions, Client ID takeover, bounded offline QoS 1/2 |
| Lifecycle | PING, Keep Alive, QoS 0/1/2 Wills, graceful SIGTERM/SIGINT shutdown |
| Persistence | Optional checksummed snapshots or explicit strict WAL with commit-before-ACK recovery |
| Security | Optional Argon2id passwords, allow-only ACLs, Principal-owned Sessions |
| Operations | TOML configuration, optional SIGHUP/config-admin reload, byte budgets and connection/auth/publish rate limits, `$SYS/broker/#` metrics, text/JSON logs |

MQTT 5, shared subscriptions, bridges, plugins, clustering and external
databases remain out of scope. `--data-dir` defaults to latest-committed
snapshot recovery; explicit `--persistence-mode strict` adds local WAL commit
barriers for the documented persistent state. It is not replication or an
end-to-end delivery guarantee. See the [compatibility matrix](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/compatibility.md)
and [persistence contract](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/persistence.md).

Optional live reload replaces a verified configuration bundle without restarting
MQTT listeners. It can rotate passwords, ACLs and existing TLS/WSS material;
see the [reload configuration and deployment contract](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/configuration.md#live-configuration-reload).
The feature is disabled by default.

## Configuration

The broker enforces [logical byte budgets and admission policies](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/resource-budgets.md).
Global and per-IP limits apply before TLS; already accepted QoS 2 handshakes do not
consume new-publication tokens. Logical bytes are not an RSS cap. Password
verification runs on a bounded native worker executor so routing stays responsive.

Start with explicit resource bounds:

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 127.0.0.1:1883 \
  --max-connections 128 \
  --max-packet-size 1048576 \
  --max-receive-buffer-size 1048576 \
  --max-sessions 1024 \
  --max-inflight-per-session 16 \
  --max-inflight-total 512 \
  --max-pending-per-session 64 \
  --max-pending-total 1024
```

Enable snapshot-based restart persistence with `--data-dir`:

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 127.0.0.1:1883 \
  --data-dir /workspace/data
```

Choose strict local durability explicitly after backing up the data
directory:

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 127.0.0.1:1883 \
  --data-dir /workspace/data \
  --persistence-mode strict
```

All settings can also be loaded from TOML. CLI options override file values:

```bash
broker --config /etc/moonbit-mqtt-broker.toml --check-config
broker --config /etc/moonbit-mqtt-broker.toml --print-effective-config
broker --config /etc/moonbit-mqtt-broker.toml
```

Inspect every option without binding a listener or creating a data directory:

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- --help
scripts/moon-docker.sh run --target native src/cmd/broker -- --version
```

## Examples

The repository includes runnable end-to-end examples:

```bash
examples/basic_pubsub.sh

# Against a broker already running at HOST PORT:
examples/persistent_session.sh 127.0.0.1 1883

examples/restart_persistence.sh
```

They demonstrate live QoS 0/1 delivery, persistent Session resume, and retained
plus offline QoS 1 recovery across broker restarts.

## Build and test

The supported development and CI target is Ubuntu 24.04 Linux/amd64 Native. The
container pins MoonBit `0.10.10+f8a486b6f`, Node.js `22.23.1`, runtime
dependencies, MQTT.js, Mosquitto clients, and behavioral reference tools.

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/moon-docker.sh fmt --check
scripts/moon-docker.sh check --target native --deny-warn
scripts/moon-docker.sh test --target native --deny-warn
scripts/moon-docker.sh build --target native
scripts/verify-release-docker.sh
```

Native password authentication and the full native test suite require the system
library `libargon2.so.1`. Installing the module from Mooncakes does not install
this OS dependency. The Docker image already includes it; on Ubuntu/Debian,
install `libargon2-1` (and `argon2` for fixture/integration checks):

```bash
sudo apt-get install libargon2-1 argon2
```

If a native test reports that Argon2id requires `libargon2.so.1`, install the
runtime or use the Docker commands above. See [security](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/security.md) for
the reproducible password fixture and the missing-runtime regression check.

The cumulative verifier also runs protocol/reference matrices, bounded workloads,
all examples, TLS/security/expiry/configuration process tests, secret and
documentation checks, and a clean-room mooncakes package build.

## Strict distribution verification

For preparation, stage criteria, troubleshooting, evidence checks and the release record template, see the [release verification runbook](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/release-verification.md).

Before a release, commit all candidate changes and run:

```bash
scripts/verify-distribution-docker.sh
# Also exercise the existing ten-minute stability profile:
RELEASE_SOAK=1 scripts/verify-distribution-docker.sh
```

This is the CI release check. It verifies exactly the committed `HEAD` in a new
Docker volume, runs the full cumulative verifier, tests the extracted Mooncakes
archive in both Debug and Release, and runs its compiled broker in four minimal
Ubuntu 24.04 images. The broker images contain no MoonBit/compiler/client tools:
no optional libraries, Argon2 only, OpenSSL only, or both. Separate client
containers exercise actual QoS 1 traffic and authentication over plaintext/TLS;
missing-library configurations must fail without a crash. Runtime containers
have no external network, run as a non-root user, and have read-only filesystems.

Evidence under `test-results/distribution/` records the source commit, package
and executable SHA-256 hashes, toolchain, image IDs, library inventories and
failure logs. CI uploads the tested package and evidence. Any failing stage
returns a nonzero exit code; the script never publishes. Re-run after any source,
version, dependency or image change. A passing run applies to these recorded
Linux/amd64 environments, not to untested operating systems or toolchains.

Native system dependencies are feature-specific: `libargon2-1` for passwords,
`libssl3t64` (OpenSSL 3) for TLS on Ubuntu 24.04, and `libgcc-s1` for the executable.
Dynamic `dlopen` dependencies are not fully represented by `ldd`; both library
inventory checks and real feature tests are required. Root-level local
`AGENTS.md`/`AGENTS.local.md` files may remain untracked; other untracked candidate
files or tracked modifications block verification. Untracked files never enter
the committed archive. Keep the verified commit/package unchanged until release.

## Documentation

- [Getting started](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/getting-started.md)
- [Configuration](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/configuration.md)
- [Security](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/security.md)
- [Release verification runbook](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/release-verification.md)
- [Local persistence](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/persistence.md)
- [Compatibility and limitations](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/compatibility.md)
- [Architecture](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/architecture.md)

## License and provenance

Licensed under the Apache License 2.0. Runtime dependencies, test-only tools,
standards, behavioral references, versions, licenses, and how each is used are
recorded in [THIRD_PARTY_NOTICES.md](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/THIRD_PARTY_NOTICES.md). The broker is
original MoonBit code; no Aedes or Mosquitto implementation source is copied.

QoS 2 uses Method B deduplication and stage-aware persistent recovery. In
snapshot mode PUBREC/PUBCOMP do not imply fsync; in strict mode their persistent
state changes pass the WAL barrier first. See [compatibility](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/compatibility.md)
and [mode migration](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/persistence.md).
