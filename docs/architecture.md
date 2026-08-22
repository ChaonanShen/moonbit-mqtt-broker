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
handle can enter `BrokerState`. M2 network reader/writer tasks will only exchange
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
