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
the next commit writes V2. Protect the data directory because snapshots include
Client IDs, filters, and application payloads.
