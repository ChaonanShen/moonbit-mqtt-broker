# M0 codec gate

## Decision

`zbhzs1/moonbit-mqtt@0.1.0` passes the offline Native codec gate and is the M0
backend. The **Go** decision is final for M0: both MQTT.js 5.15.2 and Mosquitto
2.0.18 subsequently completed a real TCP MQTT 3.1.1 CONNECT → CONNACK exchange.

The project exposes only its own `Packet`, `PacketId`, `CodecError`, and
`PacketDirection` types. Candidate types and string errors remain private to
`codec_moonbit_mqtt.mbt`. The adapter adds canonical Remaining Length checks,
direction validation, MQTT CONNECT flag validation, stable error categories,
and an explicit QoS 2 rejection.

## Method and result

- Linux x86_64 Native check/build/test succeeded with the pinned toolchain.
- `mqtt-packet@9.0.2` deterministically generated 1,000 canonical packets.
- The set contains 150 CONNECT, 100 CONNACK, 250 PUBLISH QoS 0/1, 150
  SUBSCRIBE/SUBACK, 100 UNSUBSCRIBE/UNSUBACK, 100 PUBACK, and 150
  PINGREQ/PINGRESP/DISCONNECT vectors.
- Every vector decoded to the expected packet family and direction, then
  re-encoded byte-for-byte to the Node oracle's canonical wire form.
- 29 malformed vectors cover framing, flags, protocol metadata, UTF-8/NUL,
  packet identifiers, empty packet shapes, trailing bytes, and QoS 2.
- An additional MoonBit test performs 1,000 semantic PUBLISH round trips.
- Panic/hang count: 0. Semantic/byte differences: 0.

Run:

```bash
npm ci --prefix tools/codec_oracle
npm run generate --prefix tools/codec_oracle
npm run verify --prefix tools/codec_oracle
scripts/moon-docker.sh test --target native src/protocol_adapter
scripts/moon-docker.sh run --target native src/cmd/codec_gate
```

The machine-readable result is in `docs/m0/codec-gate-report.json`.
