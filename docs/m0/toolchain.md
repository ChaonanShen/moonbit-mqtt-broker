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

The M0 image built on 2026-08-21 is Linux/amd64 with stable platform manifest
`sha256:d232d08ba0c200a948aed69b23dd524c492e47c7cab46b135b1cc95fa8dd05cd`
and config digest
`sha256:2060712123baed3c266118354957798ba32c14ae5959e882abe51d81ba60cafa`.
Its base resolves to
`ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517`.

`moon version --all` reports:

```text
moon 0.1.20260814 (a2de5b2 2026-08-14)
moonc v0.10.8+8606a5800 (2026-08-14)
moonrun 0.1.20260814 (a2de5b2 2026-08-14)
```

The resolved dependency tree is intentionally shallow:

```text
ChaonanShen/moonbit-mqtt-broker@0.1.0
├─ moonbitlang/async -> moonbitlang/async@0.20.6
└─ zbhzs1/moonbit-mqtt -> zbhzs1/moonbit-mqtt@0.1.0
```

For registry artifact traceability, the resolved candidate source file has
SHA-256 `2e1dfb577709a843ea2a4b9b3f0c23650243ff1193dec8d70483d83c3764622a`.
The upstream repository did not expose a `0.1.0` tag at verification time, so
the moving GitHub HEAD is not asserted to be identical to the registry
artifact. Upgrades change one pinned variable at a time and rerun the full
codec and runtime gates.

The pinned `moon package` reports that `--dry-run` is not implemented. M0 uses
its non-publishing `moon package --list` equivalent to validate the manifest
and audit packaged paths; CI never invokes `moon publish`.
