# M0 toolchain

The only acceptance environment is Linux x86_64.

| Component | Pinned version |
| --- | --- |
| Base image | `ubuntu:24.04` |
| MoonBit | `0.10.8+8606a5800` |
| `moonbitlang/async` | `0.20.6` |
| Candidate codec | `zbhzs1/moonbit-mqtt@0.1.0` |
| Node codec oracle | `mqtt-packet@9.0.2` |
| MQTT.js client | `mqtt@5.15.2` |

Build the toolchain image with `docker build -t moonbit-mqtt-broker-dev .` and
run MoonBit commands through `scripts/moon-docker.sh`. Source code is bind
mounted at `/workspace`; it is never copied into the image.

The exact image digest, resolved dependency tree, and command output are
recorded after the clean M0 verification run.
