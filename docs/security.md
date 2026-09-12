# Security

[中文](security.zh_CN.md) | **English**

Authentication and authorization are optional static, single-node startup
configuration. There is no online user or ACL mutation API.

## Password authentication

Set `--allow-anonymous false --password-file PATH`. Each nonblank line is
`username:encoded-hash`; only standard Argon2id encoded hashes are accepted.
Plaintext, duplicate users, malformed UTF-8, files larger than 1 MiB,
symlinks, and non-regular files fail before listen. Unknown users still incur
an Argon2id verification to reduce username timing differences. Passwords,
encoded hashes, and CONNECT secrets are never logged.

MQTT 3.1.1 has no protected credential exchange. Credentials sent over
plaintext MQTT can be observed on the network. Use TLS and verify the Broker
certificate. mTLS, certificate reload, and online secret rotation are not
claimed.

## Native runtime and reproducible tests

Password verification loads `libargon2.so.1` (or `libargon2.so`) at runtime.
The supported environment is Ubuntu 24.04 Linux/amd64 with the pinned toolchain
from the Dockerfile. Outside the image, install `libargon2-1` and `argon2` on
Ubuntu/Debian. TLS also requires OpenSSL (`libssl3t64` on Ubuntu 24.04).
Mooncakes only installs MoonBit dependencies, not OS libraries.
Without the library, a configured password file fails before listen with an
installation hint; anonymous configuration without a password file remains
available. Native authentication tests deliberately fail with that hint instead
of skipping checks or panicking on `Result::unwrap()`.

The embedded test vector uses password `correct horse`, salt `0123456789abcdef`,
Argon2id version 19, 4096 KiB memory, two iterations, one lane and a 32-byte hash.
These are public test data, not production credentials or recommended password
hashing parameters. Generate its expected encoded value with the reference CLI:

```bash
printf '%s' 'correct horse' | argon2 '0123456789abcdef' -id -e -t 2 -m 12 -p 1
```

Use `printf '%s'` to avoid adding a newline to the password. The CLI's `-m 12`
means 2^12 KiB; the encoded string contains `m=4096`. Keep the `$` characters
literal when copying hashes into shell scripts or configuration files.

Run these from the repository root inside the project container, or in the
supported environment with its prerequisites installed:

```bash
scripts/check-argon2.sh
moon test src/security/security_test.mbt src/server/broker_runtime_security_test.mbt --target native --deny-warn
tests/integration/argon2_environment.sh
```

The fixture check compares every embedded vector with the reference CLI without
rewriting expected results. The environment regression hides the Argon2 shared
library only from test child processes, checks ordinary test failures instead of
SIGABRT, and checks that password authentication cannot start without its runtime.
Both checks are included in the cumulative release verifier. Encoded hashes
containing NUL, whitespace or non-ASCII are rejected before C verification, so a
C string terminator cannot hide trailing data.

## Allow-only ACL

```text
user alice
topic read sensors/#
topic write commands/+
topic read $SYS/broker/#
```

Missing matches deny when an ACL is configured. Read grants must contain the
complete requested filter; write grants match concrete PUBLISH/Will topics. A
multi-filter SUBSCRIBE can partially succeed with `0x80` for denied entries.
Denied QoS 0 is dropped; denied QoS 1 is acknowledged but never routed or
retained. Client writes to `$SYS` are always denied. Metrics still require an
explicit matching subscription and read grant.

## Principal-owned Sessions

Sessions belong to `anonymous` or `user:<name>`. A different Principal cannot
take over, clean, or resume the same Client ID, including after restart. Disk
V1 Sessions migrate as `legacy-anonymous` and are resumable only anonymously;
the next commit writes V3. Protect the data directory because snapshots include
Client IDs, filters, and application payloads.


## Authentication resource admission

A complete request requiring password verification consumes global/IP attempt tokens once before reserving input and conservative workspace costs for its validated PHC. Bad passwords, unknown users and later resource failure do not refund consumed tokens. Anonymous connections bypass hash admission but retain connection/transport caps. Verification remains synchronous; worker isolation, running-job cancellation and policy generations are separate P0-03 work. See the [resource contract](resource-budgets.md).
