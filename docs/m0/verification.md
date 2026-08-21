# M0 verification record

Verification date: 2026-08-21. Target: Ubuntu 24.04 Linux/amd64 in Docker.

The shared acceptance entry point is:

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/m0-verify-docker.sh
```

Observed results before final clean-checkout repetition:

- `moon fmt --check`, `moon check`, `moon test`, and `moon build` passed for
  Native; 30 MoonBit tests passed.
- The async capability probe passed 10 consecutive runs.
- The codec gate passed 1,000 mqtt-packet oracle vectors, 29 malformed
  vectors, and an additional 1,000 semantic round trips with zero differences,
  panic, or hang.
- MQTT.js 5.15.2 and Mosquitto 2.0.18 received accepted MQTT 3.1.1 CONNACKs.
- The real-client smoke ran 20 consecutive times using dynamic ports without a
  residual Broker process or port conflict.
- `moon package --list` is checked for local plans, Node modules,
  secrets, logs, and generated test output.

CI builds the same Dockerfile and invokes `scripts/m0-verify-docker.sh`; it does
not publish and requires no registry token.
