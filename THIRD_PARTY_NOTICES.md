# Third-party notices

This project is Apache License 2.0. The following software, standards, and
reference projects are used or consulted for version 0.1.0.

| Item | Version / baseline | License | Use |
| --- | --- | --- | --- |
| MoonBit toolchain and core | `0.10.8+8606a5800` | MoonBit distribution terms / Apache-2.0 components | Compiler, build and core library; <https://github.com/moonbitlang/core> |
| `moonbitlang/async` | `0.20.6` | Apache-2.0 | Runtime TCP/tasks/queues/timers; <https://mooncakes.io/docs/moonbitlang/async> |
| `zbhzs1/moonbit-mqtt` | `0.1.0` | Apache-2.0 | Runtime codec adapter backend; <https://mooncakes.io/docs/zbhzs1/moonbit-mqtt> |
| `bobzhang/toml` | `0.4.3` | Apache-2.0 | Runtime maintained TOML parser; <https://github.com/moonbit-community/toml-parser> |
| Argon2 / libargon2 | Ubuntu 24.04 package | CC0 / Apache-2.0 dual license | Runtime Argon2id verification and test hash generation |
| OpenSSL | Ubuntu 24.04 package | Apache-2.0 | Native TLS backend used by `moonbitlang/async` |
| `mqtt-packet` | `9.0.2` | MIT | Test-only wire oracle; <https://github.com/mqttjs/mqtt-packet> |
| MQTT.js | `5.15.2` | MIT | Test-only interoperability/stability client; <https://github.com/mqttjs/MQTT.js> |
| Eclipse Mosquitto Broker/clients | Ubuntu `2.0.18-1build3` | EPL-2.0 OR BSD-3-Clause | Test-only clients/reference Broker; <https://mosquitto.org/> |
| Aedes | `v1.1.1`, `eac44f9920b49dd20eb0e83cc9d5c4b9038eb963` | MIT | Test-only behavioral reference; no source copied; <https://github.com/moscajs/aedes> |
| OASIS MQTT 3.1.1 | Final 2014 + errata 01 (2015) | OASIS specification notices | Normative behavior; <https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/mqtt-v3.1.1.html> |
| Ubuntu container image | `24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517` | Ubuntu image terms; packages retain their licenses | Acceptance environment; <https://hub.docker.com/_/ubuntu> |

Runtime packages are resolved by Moon. npm and Mosquitto dependencies are
development/reference-only and are not linked into the Broker executable.
Dependency license texts remain distributed by their upstream packages. No
Aedes or mqtt-packet implementation source is copied into this repository.
Generated fixtures contain protocol wire data and case metadata produced
through documented public APIs.
