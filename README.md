# moonbit-mqtt-broker

A lightweight MQTT 3.1.1 broker implemented in MoonBit. The M3 server supports
multiple TCP clients, QoS 0/1 publish/subscribe, `+`/`#` topic filters, retained
messages, QoS 0/1 Wills, PING, Keep Alive, Client ID takeover, persistent
Sessions across network connections, bounded offline QoS 1 delivery, and
reconnect replay with the original Packet ID and `DUP=1`. A pure central
runtime is the only owner of Broker, Session, inflight, and retained state;
socket tasks only exchange bytes and events.

M3 defines a versioned pure-data Snapshot V1 import/export boundary, but does
not read or write snapshot files. State therefore survives reconnects only
while the Broker process remains alive; restart persistence belongs to M4.
MQTT 5, QoS 2, TLS, WebSocket, authentication/ACL, bridging, clustering, and
external databases are outside the first release.

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
scripts/m3-verify-docker.sh
```

The last command includes every M0–M2 gate, formatting, Native check/test/build,
Packet ID and Session state regressions, persistent reconnect and raw-wire DUP
tests, Snapshot V1 validation, bounded-resource tests, plus real MQTT.js and
Mosquitto QoS 1/persistent-session interoperability in the same environment as
CI.

## Run the broker

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

Try a QoS 1 subscriber and publisher in two terminals:

```bash
mosquitto_sub -h 127.0.0.1 -p 1883 -i moonbit-sub -t 'demo/#' -q 1
mosquitto_pub -h 127.0.0.1 -p 1883 -i moonbit-pub -t demo/hello -m world -q 1
```

Available resource flags are `--max-connections`, `--max-packet-size`,
`--max-receive-buffer-size`, `--max-outbound-queue`,
`--max-runtime-events`, `--connect-timeout-ms`,
`--keep-alive-check-interval-ms`, `--max-subscriptions-per-session`,
`--max-subscriptions-total`, `--max-retained-messages`, `--max-sessions`,
`--max-inflight-per-session`, `--max-inflight-total`,
`--max-pending-qos1-per-session`, and `--max-pending-qos1-total`. `--once`
serves one complete connection and is intended for smoke tests.

Outbound transport memory is approximately bounded by `connections × outbound
queue length × maximum packet size`. Session message memory is additionally
bounded by `(max inflight total + max pending QoS 1 total) × maximum packet
size`. QoS 0 is never queued for an offline Session. QoS 2 and protocol-invalid
flows close the connection without being silently downgraded.

`--max-receive-buffer-size` limits only bytes not yet consumed by the streaming
decoder. It may equal `--max-packet-size`: a complete maximum-size packet can be
drained before a sticky suffix is read, without requiring extra chunk slack.

For a repeatable persistent-session demonstration against a running Broker,
run `examples/persistent_session.sh`. It disconnects a `clean=false` subscriber,
publishes QoS 1 while it is offline, then reconnects the same Client ID.

See [compatibility](docs/compatibility.md) and
[architecture](docs/architecture.md) for exact scope.

## License

Licensed under Apache License 2.0. Third-party dependencies and behavioral
references are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
