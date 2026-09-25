# Security

[中文](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/security.zh_CN.md) | **English**

Authentication and authorization are optional single-node configuration. There is
no per-user mutation API; when reload is enabled, a verified bundle can replace
the password database and ACL as one generation.

## Password authentication

Set `--allow-anonymous false --password-file PATH`. Each nonblank line is
`username:encoded-hash`; only standard Argon2id encoded hashes are accepted.
Plaintext, duplicate users, malformed UTF-8, files larger than 1 MiB,
symlinks, and non-regular files fail before listen. Unknown users still incur
an Argon2id verification to reduce username timing differences. Passwords,
encoded hashes, and CONNECT secrets are never logged.

MQTT 3.1.1 has no protected credential exchange. Credentials sent over
plaintext MQTT can be observed on the network. Use TLS and verify the Broker
certificate. mTLS and management-token rotation are not supported by reload.
Existing MQTT TLS/WSS server certificate material can rotate with a verified
bundle.

## Live security revocation

A successful security reload publishes the new authorization gate before
bounded cleanup runs. A deleted user or disabled anonymous principal cannot
resume a Session; owned Sessions are removed. A changed password closes idle
connections with the old credential, while the same user's persistent Session
can be resumed with the new password if still authorized. An ACL-only edit
does not force unchanged credentials to reconnect, but every new publish,
subscription, Will, pending promotion and outbound MQTT message is checked
against the current ACL. Invalid subscriptions and queued messages are
cleaned in bounded steps. If an in-flight outbound QoS 1/2 payload loses read
permission, the whole Session is evicted and a reconnect reports
`SessionPresent=false`; its other queued messages are lost too. Bytes already
written to a socket cannot be recalled. A rollback is another new generation
and does not restore evicted Sessions. See
[reload configuration](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/configuration.md#live-configuration-reload) and
[durability](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/persistence.md#reload-and-recovery).

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

A complete request requiring password verification consumes global/IP attempt tokens once before reserving input and conservative workspace costs for its validated PHC. Bad passwords, unknown users and later resource failure do not refund consumed tokens. Anonymous connections bypass hash admission but retain connection/transport caps. A bounded native pthread executor owns C copies of the password and PHC while workers run; the routing loop retains only secret-free identity metadata and consumes fixed-size results. Disconnect and timeout invalidate activation but do not free a running job early. CONNECT pipelining is held behind a one-shot reader gate until CONNACK is queued. The supported PHC envelope is at most 65536 KiB memory, 10 iterations and parallelism 4. Verify the isolation and saturation behavior with `scripts/verify-auth-isolation-docker.sh`. See the [resource contract](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/resource-budgets.md).

## Management bearer tokens

The separate [management API](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/management.md) uses explicit `metrics`,
`read`, `operator` and `config_admin` roles; none implies another. Its digest
file is startup-only and is
unrelated to the MQTT PasswordDatabase or ACL. It must be a private regular
file owned by the Broker user. Enabled management loads `libcrypto.so.3`
dynamically for CSPRNG and SHA-256; a missing library or required symbol
fails startup before listening. Disabled management does not load this
feature dependency. The listener is loopback HTTP without TLS, so guard host
access and use a secure channel for forwarding.
