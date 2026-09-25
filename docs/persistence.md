# Local persistence: snapshot and strict WAL

[中文](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/persistence.zh_CN.md) | **English**

Persistence is `off` without `--data-dir PATH`. With a data directory, the
compatible default remains `snapshot`; choose `--persistence-mode strict` (or
`[persistence] mode = "strict"`) for synchronous WAL commit barriers. In-memory
mode creates no persistence files. Snapshot mode accepts these options:

| Option | Default | Constraint |
| --- | ---: | --- |
| `--max-snapshot-bytes` | 67,108,864 | at least 24 and safe for a bounded native read |
| `--snapshot-debounce-ms` | 250 | at least 1 |
| `--snapshot-max-delay-ms` | 2,000 | at least debounce |
| `--snapshot-retry-ms` | 1,000 | at least 1 |

Snapshot tuning options without `--data-dir` are configuration errors. Strict
mode requires a data directory and rejects snapshot debounce/max-delay/retry
options. Explicit `off` with a data directory is also invalid.

## Reload and recovery

With reload enabled, off mode has only the live generation. Snapshot mode
applies the current security policy to restored Sessions before accepting
connections; its snapshot still has the asynchronous durability boundary
described below. A crash can restore pre-cleanup state, so startup must
reconcile it against the current bundle before admission.

Strict mode commits a versioned policy transition to the WAL before publishing
the generation. It durably records subsequent Session eviction, subscription
and pending-message cleanup, then marks reconciliation complete. Recovery
replays policy records and finishes unfinished cleanup before listeners bind.
The current bundle's security fingerprint must match the committed policy;
otherwise startup fails with `PolicySourceMismatch`. If activation failed
after source files were replaced, restore the matching previous bundle before
restarting. Once the policy capability has been committed, old readers that
lack it cannot open the WAL directory. Keep backups of both the data directory
and the matching configuration bundle. Reverting a policy is a new reload
generation; it does not resurrect deleted Sessions or messages.

## Snapshot files and startup

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

## Snapshot commit and failure behavior

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
Snapshot mode has no WAL and does not synchronize before PUBACK, PUBREC or PUBCOMP; debounce-window
changes may be lost after `SIGKILL`, host failure, or power loss. Natural
`--once` completion drains a final submitted revision. SIGTERM and SIGINT are
converted into a normal service-stop request: the listener and connection tasks
stop, active Wills are suppressed, and the newest in-memory revision is forced
and drained before the process exits. The process-level shutdown test uses a
60-second debounce, so the signal path must create the first snapshot.

## Strict WAL mode

Strict mode uses the same exclusive `broker.snapshot.lock` and the Disk V3
logical state, with a separate versioned checkpoint, `broker.manifest`, and
numbered `wal-<id>.log` segments. A single writer appends a complete transaction
frame and batch commit frame, then performs a full file `fsync`. The driver
installs the prepared affected-key changes and releases network actions only
after that sync succeeds. Independent transactions may share a batch (up to 64
transactions, 8 MiB and approximately 2 ms collection); conflicting writes
retain their connection order. The default single-delta encoding cap is 4 MiB.
A request whose persistent result exceeds it is refused before WAL submission;
it does not switch to snapshot semantics. Disk accounting includes checkpoints,
segments and orphan files; the default hard limit is 1 GiB with 256 MiB reserved
for rotation and checkpoint work. `--wal-disk-max-bytes` and
`--wal-disk-reserve-bytes` configure those disk limits.

A successful QoS 1 PUBACK means the retained change and every persistent
recipient state produced by that publication are committed together. QoS 2
PUBREC also commits the persistent publisher's AwaitPubrel ID; PUBCOMP follows
its committed deletion. A persistent subscriber's PUBLISH/PUBREL is released
after its outbound Packet ID and phase are committed. Persistent CONNACK,
SUBACK and UNSUBACK follow their session changes. A management delete Operation
reports `completion_scope=durable` and `committed_lsn_at_finish` only after its
delete commits. Kick waits for transport close, auth reap and durable session
cleanup. These guarantees apply through TCP, TLS, WS and WSS on the same Broker.
QoS 0 and clean sessions gain no cross-crash delivery copy merely because a
packet was acknowledged; ACL-rejected MQTT 3.1.1 publications keep the existing
acknowledge-and-drop behavior.

Recovery reads only files named by the validated manifest. Complete committed
batches replay in LSN order, even if the old process never delivered their ACK.
An incomplete active tail is truncated and synced before new writes; a complete
bad-CRC frame, missing referenced segment, broken chain, bad checkpoint or
unknown required version fails startup without an automatic fallback. The
Broker remains unready until recovery and the WAL writer are ready. A write or
sync failure, uncertain manifest publication or commit timeout fences that
process: no uncertain batch ACK is sent, MQTT business admission stops, and
read-only management diagnosis stays available with `ready=false`. Restart
under the same data directory lock is required to resolve the unknown outcome.
Checkpoint failure before publication may leave strict commits running as
`degraded`, subject to the disk cap.

On normal SIGTERM/SIGINT, accepted mutations and durable detach/cleanup drain
before the lock is released. Triggered Will routing is a successor transaction:
a crash after the trigger but before its commit can lose that Will. An unfired
Will is not reconstructed after a process crash. The guarantee after OS crash
or power loss depends on the filesystem and storage stack honoring `fsync`;
SIGKILL tests alone do not establish power-loss behavior.

### Mode migration and recovery

Stop the previous process and back up the complete directory before changing
from snapshot to strict. The first strict start imports the legacy V1/V2/V3
snapshot and publishes an initial checkpoint and manifest before listening.
Once a manifest exists, it is the sole authority; switching the directory back
to snapshot mode is rejected. Never remove the manifest to make an old binary
read a stale `broker.snapshot`. Rollback uses the stopped pre-migration backup
and discards writes accepted after that backup. Preserve the entire strict
directory before investigating a storage failure; do not edit files under a
live lock. The snapshot CLI/API remains unchanged when `strict` is not selected.

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

In snapshot mode, disk-full, permission, or runtime I/O errors leave the
Broker serving and retrying while explicitly degraded. In strict mode, an
uncertain WAL write or sync fences business admission until a restart. Lock conflict and startup recovery errors
are fatal. There is no automatic corrupt-main repair, backup fallback, or temp
promotion. Before manual recovery, stop the Broker and copy the entire data
directory. Diagnose and preserve the original files before replacing or
removing main; never edit files while a Broker holds the lock.


## Snapshot byte budgets

Export, queuing, encoding and actual writes share snapshot-work admission. Replacing a queued request releases its lease; an active write keeps its lease until save completes. Import validates category/session/global bytes before record and payload allocation without changing V1/V2/V3. Budget shortage preserves dirty state with bounded diagnostics; an uncommitted final snapshot fails shutdown rather than truncating state or silently starting empty. File type is checked before size inspection, so FIFOs, directories and symlinks are not read as snapshots. See the [resource contract and observations](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/release/0.3.0/docs/resource-budgets.md).
