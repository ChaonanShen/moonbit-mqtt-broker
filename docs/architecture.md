# Architecture

## M0 data path

```text
TCP bytes
  → bounded FrameDecoder (NeedMoreData | CompletePacket | MalformedPacket)
  → protocol_adapter (project Packet / classified CodecError)
  → first-packet CONNECT validation
  → encoded accepted CONNACK
```

`src/framing` owns TCP stream boundaries and imports no codec. The synchronous
`src/protocol_adapter` owns the stable project packet model and hides all
`zbhzs1/moonbit-mqtt` types. `src/server` is responsible for socket lifetime,
size limits, and the deliberately narrow M0 connection flow.

M0 uses sequential connection handling after accept. It does not pretend to be
the final Broker state machine.

## M1 Router boundary

The M1 Router is the only component allowed to mutate Broker, Session,
SubscriptionIndex, and Retained state. It consumes pure `BrokerEvent` values and
returns ordered pure `BrokerAction` values; no socket, task, clock, or file
handle can enter `BrokerState`. Network reader/writer tasks only exchange
bytes and bounded events/actions:

```text
TCP connection
  ├─ reader task → bounded BrokerEvent queue → Router / BrokerState
  └─ writer task ← bounded outbound queue ← BrokerAction
```

This keeps BrokerState deterministic and testable without starting TCP, while
preventing slow connections from blocking global routing or growing memory
without bounds.

Topic filters and names are validated before events are created. Overlapping
filters are merged once per client at the highest subscription QoS. Retained
storage is bounded: a new topic at capacity rejects the whole publish, while
replacement and deletion remain allowed.

All client delivery actions and retained replays use ascending lexical order of
the original UTF-8 bytes. The ordering is independent of Map iteration,
insertion order, locale, case folding, and Unicode normalization.

`SubscriptionIndex` maintains both `filter → clients` and `client → filters`
indexes. Its invariant checker proves both directions contain the same nonempty
buckets, QoS values, and pair count. `BrokerState::check_invariants` additionally
rejects subscriptions without a Session and verifies per-session, total
subscription, and retained-message limits. These checks are exercised through
white-box corruption tests and a deterministic 10,000-transition regression.

## M2 network runtime

```text
TcpServer accept loop
  └─ ConnectionSupervisor(ConnectionId, Tcp)
       ├─ reader: FrameDecoder → Packet → bounded DriverEvent queue
       ├─ writer: bounded OutboundCommand queue → bytes
       └─ independent close signal
                          │
                          ▼
                    RouterDriver
              transport registry + encoding
                          │
                          ▼
                    BrokerRuntime
        connection generations + M1 BrokerState
```

`BrokerRuntime` contains only deterministic data and accepts injected event
times. It owns connection phases, Client ID bindings, Keep Alive deadlines,
Will state, and the M1 `BrokerState`. `RouterDriver` is the only async task that
applies runtime events and modifies the transport registry. Sockets, queues,
tasks, and clocks never enter the pure runtime.

Every transport event carries a monotonically allocated `ConnectionId`.
Takeover terminates the old generation and publishes its Will before binding
the new generation; later EOF/write events from the old socket are stale
no-ops. Connection termination removes a clean Session and consumes a Will at
most once.

Outbound dispatch uses non-blocking `try_put`. A full client queue terminates
only that slow consumer, while a separate capacity-one close signal can still
interrupt blocked I/O. The global event queue is bounded and deliberately uses
backpressure so decoded Packet events are not dropped. Frame size, receive
buffer, connection count, handshake time, and both queue sizes are configured
through one validated `ServerConfig`.

The connection reader computes `max_receive_buffer_size - buffered_len` before
every socket read and uses the smaller of that capacity and 4096 bytes. It
drains every complete frame before calculating the next read. Consequently the
receive limit measures only bytes the decoder has not consumed, rather than an
arbitrary OS TCP chunk: `max_receive_buffer_size == max_packet_size` remains a
valid configuration even for a complete packet followed by sticky control
packets. A full decoder that still reports `NeedMoreData` closes with a protocol
error instead of reading past the configured bound or busy-looping.

Reader, writer, and independent closer race through a capacity-one terminal
queue. The first terminal reason closes the socket, closes both transport
queues, cancels sibling tasks, and emits exactly one `TransportClosed` followed
by `UnregisterTransport`. Later socket failures are stale generation events.

## M3 QoS 1 and persistent Sessions

`ClientSession` owns its Packet ID allocator, ordered outbound inflight array,
and ordered pending QoS 1 array. `BrokerState` owns every Session and maintains
O(1) global inflight/pending counters. `BrokerRuntime` retains only connection
generations, active Client ID bindings, Keep Alive, and Will metadata; sockets,
queues, tasks, timers, and `ConnectionId` never enter a Session or snapshot.

```text
BrokerRuntime connection generation
          │ active ClientId
          ▼
BrokerState (single writer)
  ├─ SubscriptionIndex
  ├─ RetainedStore
  └─ ClientSession
       ├─ Clean | Persistent, attached flag
       ├─ PacketIdAllocator 1..65535
       ├─ ordered QoS1 inflight
       └─ ordered offline/backpressure pending
```

An inbound QoS 1 PUBLISH is fully preflighted and committed before its same-ID
PUBACK action is emitted. Each outbound effective QoS 1 delivery receives a
recipient-Session Packet ID and is stored inflight before the wire action.
PUBACK removes only the matching Session entry and promotes pending messages in
FIFO order. Unknown or duplicate PUBACK is a legal no-op.

Persistent disconnect detaches rather than removes the Session. Reconnect sends
CONNACK first, replays existing inflight entries with their original Packet IDs
and `DUP=1`, then promotes pending entries with fresh IDs and `DUP=0`. Clean
connect removes any previous persistent state. QoS 0 is dropped while offline.
Per-Session and total limits bound Sessions, inflight, and pending state; a
client-origin QoS 1 publication fails atomically when any recipient cannot take
ownership.

Snapshot V2 is a deterministic pure-data boundary. It contains Principal
ownership and detach epoch in addition to persistent
subscriptions, inflight order/IDs, pending FIFO order, next Packet ID, and
retained messages. It excludes clean Sessions and all live connection data.
Import validates the complete snapshot and every configured limit before the
new `BrokerState` is returned, and restored Sessions start detached. M3 performs
no filesystem I/O.

## M4 local snapshot persistence

```text
RouterDriver (single BrokerState writer)
  └─ revision observation + debounce/max-delay
       └─ capacity-one latest-wins SnapshotSink
            └─ single SnapshotWriter
                 └─ temp write → full fsync → replace rename → directory fsync
```

`BrokerState.snapshot_revision` is process-local metadata. It advances only
when the deterministic Snapshot V2 export changes; it is never encoded. The
Router exports immutable snapshot data and submits without waiting for disk.
The writer serializes saves, absorbs newer revisions while retrying, and never
allows an older revision to overwrite a newer successful commit.

`src/persistence` depends on the public Router snapshot model and async file
APIs, but not on Server, sockets, protocol adapters, or Router private maps.
Router, Session, and Topic packages contain no filesystem imports.

With `--data-dir`, command startup creates and canonicalizes the directory,
acquires a process-lifetime exclusive lock, deletes stale temp data without
promoting it, and strictly loads/imports the main snapshot. Only then does
`server.run` create the listener. Missing main means first startup; corrupt,
oversize, symlink, or non-regular main is fatal. Disk V2 is canonical binary
with magic/version/flags/length and IEEE CRC-32. See `persistence.md` for the
format and operational contract.

## M6–M9 transport, security, and expiry

SIGTERM/SIGINT close the listener through the normal task group, classify
connection termination as server shutdown, suppress active Wills, force the
newest revision, and wait for the snapshot writer. TLS is implemented behind a
plain/secure `ConnectionTransport` boundary; certificate/key validation and an
in-memory handshake complete before bind, while each accepted handshake has an
independent deadline.

`SecurityPolicy` is immutable after startup. CONNECT authenticates to a
`Principal`; BrokerRuntime applies read/write ACLs before Router mutation.
ClientSession stores its owner and detach epoch, and Snapshot V2 persists both.
The V1 decoder maps old Sessions to `legacy-anonymous`, while all writers emit
V2. Cross-Principal Client ID operations are rejected before takeover or state
deletion.

Session expiry remains a pure Router event with an injected epoch. Candidates
are detached persistent Sessions sorted by detach time and UTF-8 Client ID,
bounded per tick. Time regression delays expiry and warns once; it never
accelerates deletion. Removal reuses the normal Session cleanup path and
advances the snapshot revision.

## M10 observability

`BrokerMetrics` is process-local and excluded from snapshots. Periodic
`EmitSystemMetrics` performs a read-only subscription lookup and sends direct
QoS 0, non-retained publications. It does not call the application publish
path, allocate Packet IDs, consume retained capacity, or increment its own
message counters. Runtime ACL checks still apply.

All production runtime and persistence logs use one Logger abstraction. Text
and JSON share event names and the fields timestamp, connection ID, Client ID,
Principal, peer, reason, and snapshot revision. Call sites pass summaries and
classified reasons only; credentials, keys, ACL contents, and payload bytes do
not enter records.

## M11 configuration

The maintained `bobzhang/toml` parser validates a complete document. A typed
adapter accepts only documented sections/keys and produces CLI-equivalent base
arguments; the real CLI is applied afterward, yielding CLI > TOML > defaults
without duplicating validation. Check/print modes stop before persistence open
or listener construction.
