# moonbit-mqtt-broker

A lightweight, single-node MQTT 3.1.1 Broker implemented in MoonBit. Version
`0.1.0` supports
multiple TCP or TLS clients, QoS 0/1 publish/subscribe, `+`/`#` topic filters, retained
messages, QoS 0/1 Wills, PING, Keep Alive, Client ID takeover, persistent
Sessions across network connections, bounded offline QoS 1 delivery, and
reconnect replay with the original Packet ID and `DUP=1`. Optional local
snapshot persistence carries retained and persistent-Session state across
Broker process restarts. TLS, Argon2id authentication, static allow-only ACLs,
Principal-owned Sessions, configurable Session expiry, `$SYS/broker` metrics,
structured logs, and TOML configuration are available as single-node
operational features. A pure central
runtime is the only owner of Broker, Session, inflight, and retained state;
socket tasks only exchange bytes and events.

Optional persistence encodes Snapshot V2 as checksummed Disk V2 and commits it via
a same-directory temporary file, full file sync, atomic replace rename, and
directory sync. Recovery is strict and occurs before the TCP listener is
created. This is debounced latest-committed snapshot durability, not a WAL or
per-PUBACK stable-storage guarantee. SIGTERM and SIGINT stop the listener
through the normal service path, suppress active connection Wills, and force
the newest in-memory Snapshot before exit; SIGKILL and host failure retain only
the latest-committed guarantee.
MQTT 5, QoS 2, WebSocket, shared subscriptions,
Bridge, plugins, clustering, external databases, WAL, and zero-loss durability
are outside this release.

## Prerequisites

The supported development and acceptance target is Linux x86_64 Native through
Docker on an x86_64 host. The image pins Ubuntu 24.04, MoonBit
`0.10.8+8606a5800`, Node.js
`22.23.1`, `moonbitlang/async@0.20.6`, the candidate codec, MQTT.js, and
Mosquitto clients. A host MoonBit installation is not required.

## Build and test

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/moon-docker.sh check --target native
scripts/moon-docker.sh test --target native
scripts/moon-docker.sh build --target native
scripts/m11-verify-docker.sh
```

The last command is the cumulative M0–M11 release gate: formatting,
Native check/test/build, MQTT.js/Mosquitto/Aedes protocol comparison, bounded
workloads, executable examples, documentation checks, clean-room packaging, and
real SIGTERM/SIGINT final-snapshot recovery, TLS/security, Session expiry,
observability, and TOML validation
in the same environment as CI.

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

Enable restart persistence by adding a data directory:

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 127.0.0.1:1883 \
  --data-dir /workspace/data \
  --max-snapshot-bytes 67108864 \
  --snapshot-debounce-ms 250 \
  --snapshot-max-delay-ms 2000 \
  --snapshot-retry-ms 1000
```

Enable the mutually exclusive TLS-only listener with a PEM certificate and a
private key readable only by its owner:

```bash
chmod 0600 server.key
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 127.0.0.1:8883 \
  --tls-cert /workspace/certs/server.crt \
  --tls-key /workspace/certs/server.key \
  --tls-handshake-timeout-ms 10000
```

Both TLS paths are required together. The certificate must be a regular file;
the key must be a non-symlink regular file with no group/other permissions.
The Broker loads the pair and completes a real in-memory handshake before it
binds the listener. TLS mode does not also expose plaintext MQTT on that port.

For a practical TLS + authentication + ACL deployment, store only Argon2id
encoded password hashes and define explicit permissions:

```text
# passwords (mode 0600)
alice:$argon2id$v=19$m=65536,t=3,p=1$...$...

# acl
user alice
topic read devices/#
topic write commands/+
topic read $SYS/broker/#
```

```bash
chmod 0600 server.key passwords
broker --listen 0.0.0.0:8883 \
  --tls-cert /etc/broker/server.crt --tls-key /run/secrets/server.key \
  --allow-anonymous false --password-file /run/secrets/passwords \
  --acl-file /etc/broker/acl --data-dir /var/lib/broker \
  --persistent-session-expiry 30d --log-format json
```

MQTT 3.1.1 transports credentials in CONNECT, so TLS is strongly recommended
whenever passwords are enabled. The same settings can be loaded from TOML;
CLI values override the file:

```bash
broker --config /etc/moonbit-mqtt-broker.toml --check-config
broker --config /etc/moonbit-mqtt-broker.toml --print-effective-config
broker --config /etc/moonbit-mqtt-broker.toml --listen 127.0.0.1:8883
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
`--max-pending-qos1-per-session`, and `--max-pending-qos1-total`. Persistence
is opt-in through `--data-dir`; snapshot tuning flags are rejected without it.
TLS is opt-in through `--tls-cert` plus `--tls-key`; the handshake timeout is
rejected without both credentials.
Persistent Sessions default to never expiring. Operational metrics publish
under `$SYS/broker/#`; only explicit `$SYS` subscriptions receive them.
`--log-format text|json` and `--log-level error|warn|info|debug` control logs.
`--once`
serves one complete connection and is intended for smoke tests.

Inspect every option and its fixed default without binding a listener or
creating a data directory:

```bash
scripts/moon-docker.sh run --target native src/cmd/broker -- --help
scripts/moon-docker.sh run --target native src/cmd/broker -- --version
```

Outbound transport memory is approximately bounded by `connections × outbound
queue length × maximum packet size`. Session message memory is additionally
bounded by `(max inflight total + max pending QoS 1 total) × maximum packet
size`. QoS 0 is never queued for an offline Session. QoS 2 and protocol-invalid
flows close the connection without being silently downgraded.

`--max-receive-buffer-size` limits only bytes not yet consumed by the streaming
decoder. It may equal `--max-packet-size`: a complete maximum-size packet can be
drained before a sticky suffix is read, without requiring extra chunk slack.

The examples are executable acceptance paths:

```bash
examples/basic_pubsub.sh
# Against a Broker already running at HOST PORT:
examples/persistent_session.sh 127.0.0.1 1883
examples/restart_persistence.sh
```

The first demonstrates QoS 0/1 live delivery, the second disconnects and
resumes a `clean=false` Session, and the third starts two Broker processes with
one data directory to prove retained and offline QoS 1 restart recovery.

See [persistence](docs/persistence.md), [testing](docs/testing.md),
[compatibility](docs/compatibility.md), and
[architecture](docs/architecture.md) for exact behavior and scope. See also
[security](docs/security.md) and [configuration](docs/configuration.md). Maintainers
should also use the [release runbook](docs/release.md).

## License

Licensed under Apache License 2.0. Third-party dependencies and behavioral
references are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
