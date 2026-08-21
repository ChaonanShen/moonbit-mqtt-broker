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

## Frozen future boundary

From M1 onward, the Router will be the only component allowed to mutate Broker,
Session, Retained, and inflight state. M2 network reader/writer tasks will only
exchange bytes and bounded events/actions:

```text
TCP connection
  ├─ reader task → bounded BrokerEvent queue → Router / BrokerState
  └─ writer task ← bounded outbound queue ← BrokerAction
```

This keeps BrokerState deterministic and testable without starting TCP, while
preventing slow connections from blocking global routing or growing memory
without bounds.
