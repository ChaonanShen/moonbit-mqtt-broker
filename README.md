# moonbit-mqtt-broker

[中文](README.zh_CN.md) | **English**

[![CI](https://github.com/ChaonanShen/moonbit-mqtt-broker/actions/workflows/ci.yml/badge.svg)](https://github.com/ChaonanShen/moonbit-mqtt-broker/actions/workflows/ci.yml)

A lightweight, single-node MQTT 3.1.1 broker implemented in MoonBit.

Version `0.1.0` is a usable Linux x86_64 Native release for small deployments,
local development, interoperability testing, and MoonBit MQTT applications. It
supports multiple TCP or TLS clients, QoS 0/1, wildcard subscriptions, retained
messages, Wills, Keep Alive, persistent Sessions, optional restart persistence,
authentication, ACLs, metrics, structured logs, and TOML configuration.

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

| Area | Version 0.1.0 |
| --- | --- |
| Protocol | MQTT 3.1.1 over TCP or TLS |
| Delivery | QoS 0 and QoS 1 publish/subscribe; outbound inflight replay with `DUP=1` |
| Topics | `+` and `#` filters, deterministic overlap merge, retained messages |
| Sessions | Clean and persistent Sessions, Client ID takeover, bounded offline QoS 1 |
| Lifecycle | PING, Keep Alive, QoS 0/1 Wills, graceful SIGTERM/SIGINT shutdown |
| Persistence | Optional local checksummed snapshots with strict startup recovery |
| Security | Optional Argon2id passwords, allow-only ACLs, Principal-owned Sessions |
| Operations | TOML configuration, resource limits, `$SYS/broker/#` metrics, text/JSON logs |

MQTT 5, QoS 2, WebSocket, shared subscriptions, bridges, plugins, clustering,
external databases, WAL, and zero-loss durability are intentionally out of
scope. Optional persistence provides a latest-committed snapshot guarantee,
not synchronous message durability. See the [compatibility matrix](docs/compatibility.md) for the exact
contract and limitations.

## Configuration

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
  --max-pending-qos1-per-session 64 \
  --max-pending-qos1-total 1024
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

The release verifier also runs protocol/reference matrices, bounded workloads,
all examples, TLS/security/expiry/configuration process tests, secret and
documentation checks, and a clean-room mooncakes package build.

## Documentation

- [Getting started](docs/getting-started.md)
- [Configuration](docs/configuration.md)
- [Security](docs/security.md)
- [Local persistence](docs/persistence.md)
- [Compatibility and limitations](docs/compatibility.md)
- [Architecture](docs/architecture.md)

## License and provenance

Licensed under the Apache License 2.0. Runtime dependencies, test-only tools,
standards, behavioral references, versions, licenses, and how each is used are
recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The broker is
original MoonBit code; no Aedes or Mosquitto implementation source is copied.
