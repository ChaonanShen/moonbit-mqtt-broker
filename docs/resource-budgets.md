# Resource budget primitives

The `resource_budget` package provides synchronous single-writer accounting and token buckets. This first implementation step does not yet enable byte limits in the server; integration is incremental.

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
