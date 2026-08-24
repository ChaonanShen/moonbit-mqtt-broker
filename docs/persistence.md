# Local snapshot persistence

Persistence is disabled unless `--data-dir PATH` is provided. Disabled mode is
the M3 memory-only behavior and creates no persistence files. Enabled mode
accepts these options:

| Option | Default | Constraint |
| --- | ---: | --- |
| `--max-snapshot-bytes` | 67,108,864 | at least 24 and safe for a bounded native read |
| `--snapshot-debounce-ms` | 250 | at least 1 |
| `--snapshot-max-delay-ms` | 2,000 | at least debounce |
| `--snapshot-retry-ms` | 1,000 | at least 1 |

Snapshot tuning options without `--data-dir` are configuration errors.

## Files and startup

The canonicalized data directory is mode `0700`. It contains only fixed names:

- `broker.snapshot`: committed Disk V1, mode `0600`;
- `broker.snapshot.tmp`: current uncommitted write, mode `0600`;
- `broker.snapshot.lock`: exclusive process lock, mode `0600`.

The Broker acquires the nonblocking exclusive lock before reading state and
holds it until shutdown. A second Broker using the same directory fails before
bind. After locking, stale temp is deleted best-effort and is never promoted.
Missing main is first startup. Existing main must be a non-symlink regular file
within the configured size, pass its envelope/CRC and bounded decoder, and pass
the complete Router import. Empty, truncated, corrupt, unknown-version,
oversize, duplicate-key, symlink, FIFO, device, and directory main files are
fatal. Listening starts only after successful recovery.

## Commit and failure behavior

Each save canonical-encodes in memory, creates/truncates temp, writes all bytes,
performs full file sync, closes it, atomically replaces main, and synchronizes
the directory. Failure before rename removes temp best-effort and leaves main
unchanged. Directory-sync failure after rename reports durability uncertainty:
the visible main is complete, but power-loss persistence cannot be claimed.

State changes are combined by quiet debounce and bounded by max delay. Router
submission is nonblocking and capacity one; a slow writer retains only the
latest revision. Failed saves log `persistence=degraded` and retry the newest
state. A later success logs recovery and the committed revision. Example log
forms are:

```text
snapshot restored version=1 sessions=2 retained=1 bytes=412 data_dir=/data
snapshot failed revision=8 category=filesystem persistence=degraded
snapshot persistence recovered revision=11
snapshot committed revision=11 bytes=487
```

The durability boundary is the latest successful `snapshot committed` line.
This design has no WAL and does not synchronize before PUBACK; debounce-window
changes may be lost after `SIGKILL`, signal termination, host failure, or power
loss. Natural `--once` completion drains a final submitted revision. General
signal shutdown carries only the latest-committed guarantee.

## Persisted state and recovery operations

Disk V1 contains retained messages and `clean_session=false` Sessions: client
ID, subscription QoS, outbound inflight with original Packet IDs, offline
pending QoS 1 FIFO, and next Packet ID. It excludes clean Sessions, QoS 0
offline messages, TCP connections, attached status, Keep Alive deadlines, and
unfired connection Wills. A Will already routed into retained/inflight/pending
state is included normally.

Disk V1 begins with `MBMQTT01`, envelope version 1, zero flags, unsigned
big-endian payload length, and IEEE CRC-32. Its canonical payload is the public
Snapshot V1 model. Existing version-1 bytes will not be reinterpreted; future
format changes require a new version and migration tests.

On disk-full, permission, or runtime I/O errors, the Broker continues serving
and retries while explicitly degraded. Lock conflict and startup recovery errors
are fatal. There is no automatic corrupt-main repair, backup fallback, or temp
promotion. Before manual recovery, stop the Broker and copy the entire data
directory. Diagnose and preserve the original files before replacing or
removing main; never edit files while a Broker holds the lock.
