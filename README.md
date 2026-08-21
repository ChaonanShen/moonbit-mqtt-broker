# moonbit-mqtt-broker

A lightweight MQTT 3.1.1 broker implemented in MoonBit. The project has a
bounded stream frame decoder, a pinned and gated codec adapter, Native async
runtime probes, a minimal real TCP CONNECT → accepted CONNACK service, and a
transport-independent M1 Router core for subscriptions, QoS metadata, routing,
and retained messages.

The TCP service does **not yet** expose PUBLISH/SUBSCRIBE routing, Retained or
Will delivery, Keep Alive, QoS 1 inflight state, persistent sessions, or
snapshots; network integration belongs to M2 and later milestones. MQTT 5,
QoS 2, TLS, WebSocket, authentication/ACL, bridging, clustering, and external
databases are outside the first release.

## Prerequisites

The supported development and acceptance environment is Docker on an x86_64
host. The image pins Ubuntu 24.04, MoonBit `0.10.8+8606a5800`, Node.js
`22.23.1`, `moonbitlang/async@0.20.6`, the candidate codec, MQTT.js, and
Mosquitto clients. A host MoonBit installation is not required.

## Build and test

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/moon-docker.sh check --target native
scripts/moon-docker.sh test --target native
scripts/moon-docker.sh build --target native
scripts/m1-verify-docker.sh
```

The last command runs all M0 checks plus the M1 acceptance presence gate,
formatting, Native check/test/build, Router purity audit, 1,000 topic-matcher
differential cases, and the deterministic 10,000-transition regression in the
same environment as CI.

## Run the M0 service

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 127.0.0.1:1883 --max-packet-size 1048576
```

`--once` accepts one CONNECT, returns CONNACK, and exits; it is intended for
tests. The current service deliberately closes connections that send any
unsupported packet flow.

See [compatibility](docs/compatibility.md) and
[architecture](docs/architecture.md) for exact scope.

## License

Licensed under Apache License 2.0. Third-party dependencies and behavioral
references are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
