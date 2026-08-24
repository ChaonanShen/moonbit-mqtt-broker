# Getting started

[中文](getting-started.zh_CN.md) | **English**

This guide starts a local MQTT 3.1.1 broker, verifies publish/subscribe, and
shows the safe path to persistence and authenticated TLS.

## Requirements

- Docker with Linux/amd64 container support;
- an MQTT 3.1.1 client such as Mosquitto clients or MQTT.js;
- free local ports `1883` for plaintext or `8883` for TLS.

The project container includes the required MoonBit toolchain and test clients.

## Start a plaintext broker

From the repository root:

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 0.0.0.0:1883
```

Keep that terminal open. In a second terminal, start a subscriber:

```bash
mosquitto_sub -h 127.0.0.1 -p 1883 -i demo-sub -t 'demo/#' -q 1
```

In a third terminal, publish a message:

```bash
mosquitto_pub -h 127.0.0.1 -p 1883 -i demo-pub \
  -t demo/hello -m 'hello from MoonBit' -q 1
```

The subscriber should print `hello from MoonBit`.

## Use a configuration file

Copy the example in [configuration](configuration.md) to a local TOML file.
Validate it before starting the broker:

```bash
broker --config /etc/moonbit-mqtt-broker.toml --check-config
broker --config /etc/moonbit-mqtt-broker.toml --print-effective-config
broker --config /etc/moonbit-mqtt-broker.toml
```

Unknown, duplicate, malformed, or incorrectly typed settings fail before the
listener opens. Command-line values override TOML values.

## Enable restart persistence

Pass a private data directory:

```bash
mkdir -p data
chmod 0700 data
scripts/moon-docker.sh run --target native src/cmd/broker -- \
  --listen 0.0.0.0:1883 \
  --data-dir /workspace/data
```

Stop with SIGTERM or SIGINT so the broker drains the newest snapshot. SIGKILL,
host failure, and power loss retain only the latest completed snapshot. Read
[local persistence](persistence.md) before relying on restart recovery.

## Enable TLS, passwords, and ACLs

Use a certificate and an owner-only private key. Store only Argon2id encoded
password hashes:

```text
# /run/secrets/mqtt-passwords, mode 0600
alice:$argon2id$v=19$m=65536,t=3,p=1$...$...
```

Define allow-only permissions:

```text
# /etc/moonbit-mqtt-broker.acl
user alice
topic read devices/#
topic write commands/+
topic read $SYS/broker/#
```

Then start a TLS-only listener:

```bash
chmod 0600 server.key /run/secrets/mqtt-passwords
broker --listen 0.0.0.0:8883 \
  --tls-cert /etc/broker/server.crt \
  --tls-key /etc/broker/server.key \
  --allow-anonymous false \
  --password-file /run/secrets/mqtt-passwords \
  --acl-file /etc/moonbit-mqtt-broker.acl
```

MQTT 3.1.1 credentials are visible on plaintext connections. Use TLS whenever
password authentication is enabled. See [security](security.md) for file and
authorization rules.

## Run the examples and tests

```bash
examples/basic_pubsub.sh
examples/restart_persistence.sh
scripts/verify-release-docker.sh
```

The full verifier builds, tests, runs interoperability scenarios and examples,
checks documentation and secrets, and reconstructs the mooncakes package in a
clean directory.

## Operational boundaries

This release is single-node and Linux x86_64 Native. It does not implement
MQTT 5, QoS 2, WebSocket, clustering, bridges, plugins, external databases,
WAL, or zero-loss durability. Review the [compatibility matrix](compatibility.md)
before deployment.
