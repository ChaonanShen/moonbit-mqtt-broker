# Architecture

[中文](architecture.zh_CN.md) | **English**

The broker uses a single-writer runtime for all mutable MQTT state. Connection
tasks own sockets and byte buffers; they cannot mutate Sessions, subscriptions,
retained messages, or persistence state directly.

```text
TCP or TLS connection
  ├─ reader → bounded frame decoder → protocol adapter → runtime event queue
  ├─ writer ← bounded outbound queue ← ordered runtime actions
  └─ closer → connection generation and terminal-reason handling
                                      │
                                      ▼
                                 RouterDriver
                                      │
                                      ▼
              BrokerRuntime + BrokerState (single writer)
                ├─ Sessions and Packet ID ownership
                ├─ SubscriptionIndex and RetainedStore
                ├─ authentication and authorization decisions
                └─ snapshot revisions and metrics
```

## Protocol boundary

`src/framing` turns a bounded TCP byte stream into complete MQTT frames.
`src/protocol_adapter` owns the project's packet model and isolates the
third-party codec. Direction, flags, sizes, and supported QoS combinations are
validated before a packet reaches broker state.

Malformed input, an invalid first packet, duplicate CONNECT, or an
unsupported flow closes only the affected connection.

## State and routing

`BrokerState` is deterministic and contains no sockets, tasks, clocks, or file
handles. It consumes events and returns ordered actions. Subscription indexes
are maintained in both directions, overlapping filters are merged at the
highest effective QoS, and delivery order is based on the original UTF-8 bytes
rather than map iteration order.

Each persistent Session owns its Packet ID allocator, ordered outbound
inflight entries, and offline QoS 1/2 FIFO. Reconnect sends CONNACK first, replays
PUBLISH with original IDs and DUP=1 or AwaitPubcomp as PUBREL, then promotes queued
messages. Per-Session and global limits bound all retained, subscription,
inflight, pending, connection, event, and transport queues.

## Connection isolation

Every accepted transport has a monotonically allocated connection generation.
Client ID takeover closes the old generation; late reader or writer events from
that socket become no-ops. A full outbound queue disconnects only the slow
consumer, while the bounded global event queue applies backpressure without
dropping decoded packets.

TLS is implemented behind the same transport interface as plaintext TCP.
Credential validation occurs before listen, and every accepted handshake has
an independent deadline.

## Persistence

When `--data-dir` is enabled, the runtime exports immutable Snapshot V3 values
to a capacity-one, latest-wins writer:

```text
state revision → debounce/max-delay → snapshot writer
  → temporary file → file sync → atomic replace → directory sync
```

Only the latest successful commit is durable. Recovery validates the complete
file and imports state before creating the listener. The storage design is a
local snapshot, not a WAL or synchronous per-PUBACK durability mechanism. See
[local persistence](persistence.md) for the exact failure contract.

## Security and operations

Authentication creates a `Principal`; ACL checks run before state mutation.
Persistent Sessions retain their owner across restart, preventing another
Principal from taking over or deleting the same Client ID. Passwords, hashes,
keys, ACL contents, and payloads are excluded from logs.

Metrics are process-local and excluded from snapshots. `$SYS/broker/#`
messages use an isolated QoS 0 path, do not count themselves, do not consume
retained capacity, and still require an explicit matching subscription and ACL.

## QoS 2 exchange boundary

The first accepted QoS 2 PUBLISH commits inbound Packet ID metadata, routing and
retained effects in one single-writer event (MQTT 3.1.1 Method B). A duplicate
uncompleted ID only receives PUBREC, even if DUP is clear or payload differs.
PUBREL removes that record and receives PUBCOMP; an unknown PUBREL also receives
PUBCOMP. ACL-denied publications use the same bounded handshake without routing.

Outbound QoS 1/2 share Packet IDs and inflight capacity. PUBREC releases the
QoS 2 topic/payload while retaining an AwaitPubcomp slot. PUBCOMP releases the ID
and promotes pending FIFO messages. Persistent reconnect sends CONNACK first,
replays PUBLISH with original ID and DUP=1, and replays AwaitPubcomp as PUBREL
with fixed header 0x62. Unknown PUBREC receives stateless PUBREL; confirmations
for an existing but incompatible phase close the connection.

The guarantee applies to each MQTT exchange. Downstream QoS 1 can still repeat.
PUBREC/PUBCOMP do not imply fsync: crash recovery remains latest-committed
snapshot recovery, without end-to-end exactly-once or zero-loss durability.
