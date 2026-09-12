# Local snapshot persistence

[中文](persistence.zh_CN.md) | **English**

Persistence is disabled unless `--data-dir PATH` is provided. In memory-only
mode the broker creates no persistence files. Enabled mode
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

- `broker.snapshot`: committed Disk V3 (readable legacy V1/V2), mode `0600`;
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
snapshot restored version=1-or-2-or-3 sessions=2 retained=1 bytes=412 data_dir=/data
snapshot failed revision=8 category=filesystem persistence=degraded
snapshot persistence recovered revision=11
snapshot committed revision=11 bytes=487
```

The durability boundary is the latest successful `snapshot committed` line.
This design has no WAL and does not synchronize before PUBACK, PUBREC or PUBCOMP; debounce-window
changes may be lost after `SIGKILL`, host failure, or power loss. Natural
`--once` completion drains a final submitted revision. SIGTERM and SIGINT are
converted into a normal service-stop request: the listener and connection tasks
stop, active Wills are suppressed, and the newest in-memory revision is forced
and drained before the process exits. The process-level shutdown test uses a
60-second debounce, so the signal path must create the first snapshot.

## Persisted state and recovery operations

Disk V3 contains retained messages and persistent Sessions: Client ID, Principal,
detach epoch, next Packet ID, subscriptions, inbound AwaitPubrel IDs, ordered
outbound AwaitPuback/AwaitPubrec/AwaitPubcomp records, and pending QoS 1/2 FIFO.
AwaitPubcomp has no topic/payload. Clean Sessions, offline QoS 0, live transports,
Keep Alive timers and unfired Wills are excluded.

The 24-byte envelope is unchanged: magic MBMQTT01, big-endian u16 version=3,
u16 flags=0, u64 payload length, and IEEE CRC-32. Payload integers are big endian;
strings and byte arrays have a u32 byte length prefix.

| V3 payload order | Encoding |
| --- | --- |
| Model, Sessions | u32 version=3, u32 count |
| Session identity | string Client ID, string Principal, string nonnegative detach milliseconds, u16 next Packet ID |
| Subscriptions | u32 count; string filter, u8 QoS 0..2 |
| Inbound QoS 2 | u32 count; nonzero unique u16 IDs in receive order |
| Outbound inflight | u32 count; nonzero unique u16 ID, u8 phase 1/2/3; message only for phase 1/2 |
| Pending | u32 count; messages in FIFO order |
| Message | string topic, bytes payload, u8 retain 0/1, u8 QoS 1/2 |
| Retained, after all Sessions | u32 count; string topic, bytes payload, u8 QoS 0..2 |

Phases 1/2/3 mean AwaitPuback/AwaitPubrec/AwaitPubcomp. Message QoS must match
phase 1/2; phase 3 must not contain a message. Ordered arrays preserve PUBLISH
order and first-PUBREC order without a wrapping sequence counter. Decode and
Router import validate the entire state and configured limits before listen.
Current public snapshot types use V3 suffixes; inflight messages are optional
and pending messages explicitly carry QoS.

### V1/V2 migration and rollback

Old envelopes retain their exact layouts and QoS 0/1 restrictions. Legacy
inflight becomes AwaitPuback, pending becomes QoS 1, and inbound QoS 2 starts
empty. V1 Sessions receive LegacyAnonymous and an unknown detach epoch; V2
retains its Principal and epoch. The next state-changing or shutdown commit
writes V3. Fixed, nonempty V1/V2 and V3 golden fixtures cover these conversions.

Stop the old Broker and back up the full data directory before upgrading.
After the first V3 commit, a V1/V2-only binary cannot read this directory.
Rollback requires stopping the new Broker, preserving its V3 directory, and
restoring the stopped old-version backup. State accepted after that backup is
discarded by rollback. There is no implicit V3-to-V2 downgrade.

On disk-full, permission, or runtime I/O errors, the Broker continues serving
and retries while explicitly degraded. Lock conflict and startup recovery errors
are fatal. There is no automatic corrupt-main repair, backup fallback, or temp
promotion. Before manual recovery, stop the Broker and copy the entire data
directory. Diagnose and preserve the original files before replacing or
removing main; never edit files while a Broker holds the lock.


## Snapshot byte budgets

Export, queuing, encoding and actual writes share snapshot-work admission. Replacing a queued request releases its lease; an active write keeps its lease until save completes. Import validates category/session/global bytes before record and payload allocation without changing V1/V2/V3. Budget shortage preserves dirty state with bounded diagnostics; an uncommitted final snapshot fails shutdown rather than truncating state or silently starting empty. File type is checked before size inspection, so FIFOs, directories and symlinks are not read as snapshots. See the [resource contract and observations](resource-budgets.md).
