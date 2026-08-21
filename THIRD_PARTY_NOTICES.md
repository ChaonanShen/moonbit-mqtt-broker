# Third-party notices

This project is Apache License 2.0. The following software, standards, and
reference projects are used or consulted in M0.

| Item | Version / baseline | License | M0 use |
| --- | --- | --- | --- |
| MoonBit toolchain and core | `0.10.8+8606a5800` | MoonBit distribution terms / Apache-2.0 components | Compiler, build and core library |
| `moonbitlang/async` | `0.20.6` | Apache-2.0 | Native TCP, tasks, queues, timers, cancellation |
| `zbhzs1/moonbit-mqtt` | `0.1.0` | Apache-2.0 | Runtime codec backend behind a project adapter |
| `mqtt-packet` | `9.0.2` | MIT | Development-only deterministic wire oracle |
| MQTT.js | `5.15.2` | MIT | Development-only real-client CONNECT smoke |
| Eclipse Mosquitto clients | Ubuntu package `2.0.18` | EPL-2.0 OR BSD-3-Clause | Development-only interoperability smoke |
| Aedes | `v1.1.1`, `eac44f9…` | MIT | Fixed architectural/behavioral reference; no M0 source copied |
| OASIS MQTT 3.1.1 | Final specification + errata | OASIS specification notices | Normative protocol behavior |
| Ubuntu container image | `24.04`, digest recorded in toolchain doc | Ubuntu image terms; bundled packages retain their licenses | Reproducible build/test environment |

Dependency license texts are distributed by their upstream packages. No Aedes
or mqtt-packet implementation source is copied into this repository. Generated
fixtures contain protocol wire data and case metadata produced through the
documented public APIs.
