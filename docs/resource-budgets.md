# Resource budget primitives

The `resource_budget` package provides synchronous single-writer accounting and token buckets. Router/session byte admission is integrated, including retained/subscription/session identity, bidirectional QoS state and reconstruction from V1/V2/V3 snapshots. Transport, CLI/TOML, native monotonic time and connection/traffic admission are integrated. Snapshot export, encoding, queued/active writes and import workspace share the same ledger.

## Ownership and admission

`Ledger` shares global, ordinary/control partition, and category counters. `Pool` adds local accounts for a connection or a session; several categories can share one aggregate account. An account belongs to one ledger, and duplicate category creation cannot reset its limit. Ordinary reservations cannot borrow the control partition.

`reserve` atomically checks all allocation dimensions. A returned `Ticket` starts reserved, `commit` changes it to committed, and `release` returns the charge exactly once. `replace` atomically transfers a ticket between pools or changes its amount, preserving the previous state on failure. Dequeuing an object is not a release: the reader/writer still owns its ticket until disposal. Counters are not a resident-memory measurement.

The ledger keeps category accounts, not an unbounded ticket history or owner registry. Owner accounts have the same lifetime as their objects. Live ticket count is bounded even for zero-byte reservations. No callback, await or cross-thread mutation is allowed in accounting operations. Fixed infrastructure can use one parent ticket with bounded slot leases; do not charge the same storage again for each lease.

## CostV1

| Object | Logical bytes |
| --- | --- |
| Message | UTF-8 topic + payload + 96 |
| Subscription | UTF-8 filter + 64 |
| Session identity | UTF-8 client ID + UTF-8 stored owner + 256 |
| Inbound QoS 2 / outbound AwaitPubcomp metadata | 64 |
| Wire frame | Complete encoded frame length |

Cost constants define logical quotas, not MoonBit object or allocator sizes. Simultaneously live copies are separate objects; moving ownership does not create another copy. The UTF-8 length helper scans code points without allocating an encoded copy. Public checked arithmetic rejects negative operands and overflow before adding or multiplying.

## Rate admission

`admit` accepts up to 16 bucket/cost constraints and coalesces duplicate bucket identities. All refills and debits commit together; rejection leaves every bucket unchanged. Memory release never refunds a rate token. Rate zero means no refill, burst zero allows no positive charge; disabling a policy is a separate configuration choice.

Time is a nonnegative monotonic millisecond value supplied by the caller. Regressions mint no tokens, fractional refill is retained, and large elapsed/rate products saturate safely at burst. Idle key reclamation must wait until all associated buckets are full, not just until a TTL expires.

Tests cover exact limits, multidimensional rollback, full-global transfers, control reserve, foreign owners, bounded zero-byte tickets, 10,000 fixed-seed model operations, fractional refill and Int64 boundaries.

## Router admission

Router preparation reserves destination usage and the temporary copies of existing recipient backlogs before constructing replacement sessions. Strict client fanout and retained state roll back together. Inbound QoS 2 metadata is admitted before routing, including self-subscription. PUBREC releases message storage but retains the 64-byte AwaitPubcomp record and packet identifier; PUBCOMP releases the remainder.

ACK completion is independent of pending promotion. A bounded rotating scan revisits other attached sessions after capacity is released. A blocked FIFO head remains queued and does not allow later messages to pass. Restoration recomputes derived bytes rather than trusting snapshot counters, and a snapshot that exceeds configured budgets is rejected without truncating it.

The public standalone router API transfers returned action objects to its caller; their subsequent storage is caller-owned. Server integration must retain its action/encoding leases until dispatch, in addition to the router-owned persistent state.

## Transport and control progress

The server shares its router ledger with readers, runtime packets and sinks. Read buffers, decoder extraction and packet decoding are reserved before allocation. A producer waiting for runtime capacity holds its own packet ticket and waits on a readiness-only channel, so cancellation cannot leave payload references in a cancelled dependency queue writer.

Registration, terminal notification and unregister have bounded per-connection control slots; ticks coalesce. A terminal waits for that connection's admitted packets, while registrations cannot be bypassed when scheduling alternates between control and data. Protocol packets remain in FIFO order. Control packet work/frames use a protected partition while sharing the same per-connection and aggregate event/frame caps.

A dequeued outbound frame keeps its ticket through the actual write. Queue close releases queued frames, not the frame a writer still holds. Encoding reserves before creating the frame. Server dispatch retains routing/action leases until it finishes mapping and sending actions, including any generated Will chain. Writer completion and periodic control ticks revisit pending sessions in bounded batches.

## Connection activation and rate policy

TCP connections acquire global/IP admission before TLS and retain it through transport shutdown. Peer keys omit ports and normalize IPv4-mapped IPv6. IP records are bounded, and idle eviction requires no live/reference owners and fully refilled buckets. Publish buckets follow persistent sessions across reconnects. Raw ingress is billed once per actual read, while already accepted QoS 2 exchanges bypass new-business debits. QoS 1 DUP does not bypass admission.

`limits.enabled` and `limits.per_ip_enabled` default to true. A false rate switch disables token-bucket policy, not byte accounting; the separate IP switch also disables the per-IP concurrent connection cap. Invalid/unsupported configuration is rejected, CLI overrides TOML, and printed effective configuration round-trips through the parser.

Authentication attempts requiring a verifier consume rate tokens once before memory admission. A fixed native worker pool and W+Q task table isolate Argon2 from the single routing writer. Queued and running tasks hold C-owned input and conservative PHC-derived workspace reservations until actual completion; disconnect and timeout only invalidate activation. Completion polling has a dedicated coalesced control slot, and results are reaped independently of transport registration.

Will storage is charged before copying and retained until orderly release or the completion of its internal publish. New connection activation prepares session state and all fallible allocations before retiring the old transport. Its CONNACK frame and encoding workspace are also reserved first. On takeover, the new connection's CONNACK precedes replay and any old Will delivery to that new connection. Failed preparation leaves the old connection and Will intact.

## Snapshot workspace and failure handling

Exports reserve a conservative overlap estimate before copying. The queue owns accepted request leases; replacing an older queued request releases that request, while an active writer retains its separate lease through save/sync completion. Cancellation cleans the active and queued leases. A closed writer does not retry a failed final save forever, and shutdown reports failure if dirty state was not committed.

Import checks file type before opening (including size inspection), rejects excessive file size, and reserves read/decode/restore overlap in the ledger returned with the restored broker. The decoder peeks lengths and cumulatively checks category/session/global costs before allocating records or message copies. Binary writers check their output cap before buffer growth. Disk V3 and V1/V2 compatibility remain unchanged; resource counters are derived, not persisted.

The conservative export estimate is eight times persistent/retained CostV1 plus 1024 bytes; import reserves four file-buffer lengths plus four times decoded CostV1, in addition to installed state. These are admission headroom estimates, not RSS measurements. A high backlog may defer snapshots under a small workspace limit. The dirty revision remains pending, diagnostics are rate-limited, and final shutdown cannot claim that an uncommitted snapshot was saved.

## Management accounting

The optional management service uses ordinary ledger categories
`management_infrastructure`, `management_request` and `management_cache`.
Detail/operation mode adds `management_index`, `management_query`,
`management_cursor`, `management_operation` and `management_audit`. All share
one management aggregate cap and cannot borrow the protected MQTT control
reserve. With management disabled, these pools and tickets are not created.
With details or operations disabled, their corresponding tables and byte
reservations are absent.

The A-only defaults reserve one parent ticket of 5,892,096 logical bytes
under an 8 MiB local cap: 106,496 infrastructure, 4,734,976 for 16 HTTP
request slots and 1,050,624 for the current/building observation workspaces.
Each accepted HTTP connection leases one already charged request slot through
its final write or cancellation. The parent is released only after the
acceptor, cache and outstanding leases have ended.

When both B switches are on with default sizes, the parent fee is
19,679,232 logical bytes, so a deployment must set a larger
`max_bytes_total` (the documented example uses 32 MiB). The additional
reservations are: 8,388,608 for the full conservative index cap, 4,210,688
for 16 query/result slots, 131,072 for 256 cursor records, 532,480 for
256 Operation records and 16 command envelopes, and 524,288 for 1024 audit
events. The actual index capacity formula is 256 bytes per maximum Session,
192 per MQTT connection, 192 per maximum subscription and 128 per maximum
retained entry. Startup rejects a configuration whose computed fee exceeds
`max_index_bytes`, while the ledger conservatively reserves that full cap.
This is a logical upper bound, not RSS accounting or proof that real allocator
overhead exactly matches the fee.

Slot/free-list/reverse metadata does not own message payloads. Query work
scans at most `query_scan_limit` slots per turn and owns each response until
the HTTP request slot copies or discards it. A cancelled query uses a
generation check so a late producer cannot fill a reused slot. Accepted
Operations remain owned after HTTP disconnect. Running kick state stays
bounded by `max_running_operations` and is not reclaimed until transport
terminal/unregister and every associated native authentication task is
reaped. Terminal records, idempotency entries, cursors and audit slots are
reclaimed by bounded maintenance scans or fixed-ring overwrite. An index
invariant failure closes detail/write availability without changing MQTT
business admission. These reservations remain subject to the Broker's global
ordinary ledger; a failed atomic parent reservation leaves no partial byte
charge.

## Resource observations

Additional `$SYS/broker/` topics are `resources/used_bytes`, `resources/reserved_bytes`, `resources/rejections`, `resources/usage`, `limits/rejections`, `persistence/budget_deferred` and `persistence/oldest_dirty_age_ms`. `resources/usage` is a bounded JSON object keyed by resource category with used/reserved/limit values. Control frame/runtime subcaps are folded into their canonical outbound/runtime categories so summing categories does not double-count memory. `limits/rejections` uses fixed operation names, never IP/client/topic labels.

Reservation rejections identify the violated scope and account label with used/requested/limit values. Rejection counters describe admission attempts, including optional promotion attempts, not just closed clients. Oldest dirty age tracks actual writer completion rather than queue submission. Prometheus and an administration API remain separate work.

IP expiry rotates through at most 32 existing keys without collecting the entire key table or obtaining a new memory reservation. A key has exactly one rotation entry; cleanup remains possible when the control workspace is otherwise occupied. Fixed server infrastructure reserves 16 KiB of bookkeeping space in addition to queue slots. The `max_auth_result_bytes_total` key bounds completed authentication records until the single-writer loop reaps them; cancellation and timeout do not release running native work early.
