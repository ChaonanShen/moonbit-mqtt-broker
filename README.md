# moonbit-mqtt-broker

A lightweight MQTT 3.1.1 broker implemented in MoonBit. The M2 server supports
multiple TCP clients, QoS 0 publish/subscribe, `+`/`#` topic filters, retained
messages, QoS 0 wills, PING, Keep Alive, clean-session Client ID takeover, and
bounded network queues. A pure central runtime is the only owner of Broker and
Session state; socket tasks only exchange bytes and events.

M2 intentionally supports only `clean_session=true` and QoS 0 publications.
Persistent sessions, QoS 1 PUBLISH/PUBACK/inflight state, offline delivery, and
restart snapshots are planned for M3/M4. MQTT 5, QoS 2, TLS, WebSocket,
authentication/ACL, bridging, clustering, and external databases are outside
the first release.

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
scripts/m2-verify-docker.sh
```

The last command includes all M0/M1 gates, formatting, Native check/test/build,
at least 48 M2 server test blocks, the 10,000-event runtime regression, equal
packet/receive-buffer boundaries, slow-consumer isolation, protocol-error Will,
supervisor shutdown and bounded-queue tests, plus real MQTT.js and Mosquitto
interoperability in the same environment as CI.

## Run the broker

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 127.0.0.1:1883 \
  --max-connections 128 \
  --max-packet-size 1048576 \
  --max-receive-buffer-size 1048576
```

Try a QoS 0 subscriber and publisher in two terminals:

```bash
mosquitto_sub -h 127.0.0.1 -p 1883 -i moonbit-sub -t 'demo/#' -q 0
mosquitto_pub -h 127.0.0.1 -p 1883 -i moonbit-pub -t demo/hello -m world -q 0
```

Available resource flags are `--max-connections`, `--max-packet-size`,
`--max-receive-buffer-size`, `--max-outbound-queue`,
`--max-runtime-events`, `--connect-timeout-ms`,
`--keep-alive-check-interval-ms`, `--max-subscriptions-per-session`,
`--max-subscriptions-total`, and `--max-retained-messages`. `--once` serves one
complete connection and is intended for smoke tests.

Outbound memory is approximately bounded by `connections × outbound queue
length × maximum packet size`; increasing all three limits multiplies the
worst-case budget. Unsupported QoS 1 PUBLISH/PUBACK and protocol-invalid flows
close the connection. `clean_session=false` and QoS 1 Will receive a non-zero
CONNACK and are closed without silently degrading semantics.

`--max-receive-buffer-size` limits only bytes not yet consumed by the streaming
decoder. It may equal `--max-packet-size`: a complete maximum-size packet can be
drained before a sticky suffix is read, without requiring extra chunk slack.

See [compatibility](docs/compatibility.md) and
[architecture](docs/architecture.md) for exact scope.

## License

Licensed under Apache License 2.0. Third-party dependencies and behavioral
references are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
