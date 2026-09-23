# moonbit-mqtt-broker

[中文](README.zh_CN.md) | **English**

[![CI](https://github.com/ChaonanShen/moonbit-mqtt-broker/actions/workflows/ci.yml/badge.svg)](https://github.com/ChaonanShen/moonbit-mqtt-broker/actions/workflows/ci.yml)

A lightweight, single-node MQTT 3.1.1 broker implemented in MoonBit.

Version `0.2.0` is a usable Linux x86_64 Native release for small deployments,
local development, interoperability testing, and MoonBit MQTT applications. It
supports multiple TCP or TLS clients, QoS 0/1/2, wildcard subscriptions, retained
messages, Wills, Keep Alive, persistent Sessions, optional restart persistence,
authentication, ACLs, metrics, structured logs, and TOML configuration.

The optional [read-only management API](docs/management.md) provides
loopback health checks, scoped Prometheus metrics and a status summary. It is
disabled by default and uses a separate private token file.

## What is new in 0.2.0

- Complete bidirectional QoS 2 with duplicate handling, reconnect replay, offline delivery, retained messages, Wills and Snapshot V3 recovery.
- Logical byte budgets and default-enabled connection, authentication and publish admission limits keep overload bounded.
- A bounded native authentication executor keeps expensive Argon2id verification off the routing loop and reports saturation through stable metrics.

Before upgrading a persistent deployment, read the [V3 migration and rollback notes](docs/persistence.md) and review the [default resource and rate limits](docs/configuration.md).

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
security example, read the [getting-started guide](docs/getting-started.md).

## Features

| Area | Version 0.2.0 |
| --- | --- |
| Protocol | MQTT 3.1.1 over TCP or TLS |
| Delivery | QoS 0/1/2 publish/subscribe; phase-aware PUBLISH/PUBREL replay |
| Topics | `+` and `#` filters, deterministic overlap merge, retained messages |
| Sessions | Clean and persistent Sessions, Client ID takeover, bounded offline QoS 1/2 |
| Lifecycle | PING, Keep Alive, QoS 0/1/2 Wills, graceful SIGTERM/SIGINT shutdown |
| Persistence | Optional local checksummed snapshots with strict startup recovery |
| Security | Optional Argon2id passwords, allow-only ACLs, Principal-owned Sessions |
| Operations | TOML configuration, byte budgets and connection/auth/publish rate limits, `$SYS/broker/#` metrics, text/JSON logs |

MQTT 5, WebSocket, shared subscriptions, bridges, plugins, clustering,
external databases, WAL, and zero-loss durability are intentionally out of
scope. Optional persistence provides a latest-committed snapshot guarantee,
not synchronous message durability. See the [compatibility matrix](docs/compatibility.md) for the exact
contract and limitations.

## Configuration

The broker enforces [logical byte budgets and admission policies](docs/resource-budgets.md).
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

Enable local restart persistence with `--data-dir`:

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 127.0.0.1:1883 \
  --data-dir /workspace/data
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
runtime or use the Docker commands above. See [security](docs/security.md) for
the reproducible password fixture and the missing-runtime regression check.

The cumulative verifier also runs protocol/reference matrices, bounded workloads,
all examples, TLS/security/expiry/configuration process tests, secret and
documentation checks, and a clean-room mooncakes package build.

## Strict distribution verification

For preparation, stage criteria, troubleshooting, evidence checks and the release record template, see the [release verification runbook](docs/release-verification.md).

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

- [Getting started](docs/getting-started.md)
- [Configuration](docs/configuration.md)
- [Security](docs/security.md)
- [Release verification runbook](docs/release-verification.md)
- [Local persistence](docs/persistence.md)
- [Compatibility and limitations](docs/compatibility.md)
- [Architecture](docs/architecture.md)

## License and provenance

Licensed under the Apache License 2.0. Runtime dependencies, test-only tools,
standards, behavioral references, versions, licenses, and how each is used are
recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The broker is
original MoonBit code; no Aedes or Mosquitto implementation source is copied.

QoS 2 uses Method B deduplication and stage-aware persistent recovery. PUBREC and
PUBCOMP do not imply fsync; the durability boundary remains the latest-committed
snapshot. See [compatibility](docs/compatibility.md) and [V3 migration](docs/persistence.md).
