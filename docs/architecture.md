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
