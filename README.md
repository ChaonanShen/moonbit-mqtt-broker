# moonbit-mqtt-broker

A lightweight MQTT 3.1.1 broker implemented in MoonBit. The project is at the
M0 foundation milestone: it provides a bounded stream frame decoder, a pinned
and gated codec adapter, Native async runtime probes, and a minimal real TCP
CONNECT → accepted CONNACK service.

It does **not yet** route PUBLISH messages, manage subscriptions, implement
Retained or Will delivery, Keep Alive, QoS 1 inflight state, persistent
sessions, or snapshots. MQTT 5, QoS 2, TLS, WebSocket, authentication/ACL,
bridging, clustering, and external databases are outside the first release.

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
scripts/m0-verify-docker.sh
```

The last command runs formatting, Native check/test/build, 1,000 oracle codec
vectors, malformed codec cases, MQTT.js/Mosquitto TCP smoke tests, and a
Mooncakes package content check in the same environment as CI.

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
