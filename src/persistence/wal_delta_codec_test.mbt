///|
fn wal_delta_limits() -> SnapshotDecodeLimits {
  SnapshotDecodeLimits::new(
    @router.BrokerConfig::new(4, 16, 8, max_sessions=8).unwrap(),
    1024,
  ).unwrap()
}

///|
test "durable delta codec preserves keyed session and retained results" {
  let delta : @router.DurableDelta = {
    session_puts: [
      {
        expected_generation: 4L,
        generation: 4L,
        session: {
          client_id: "client-a",
          owner_principal: "anonymous",
          detached_at_ms: 0L,
          next_packet_id: 11,
          subscriptions: [{ filter: "state/#", qos: 1 }],
          inbound_qos2: [7],
          inflight: [],
          pending: [],
        },
      },
    ],
    session_deletes: [{ client_id: "client-b", expected_generation: 3L }],
    retained_puts: [{ topic: "state/online", payload: b"yes", qos: 1 }],
    retained_deletes: ["state/old"],
  }
  let encoded = encode_durable_delta(delta).unwrap()
  assert_eq(encoded, encode_durable_delta(delta).unwrap())
  assert_eq(decode_durable_delta(encoded, wal_delta_limits()), Ok(delta))
  let changed = encoded.to_array()
  changed[20] = changed[20] ^ 1
  assert_true(
    decode_durable_delta(Bytes::from_array(changed), wal_delta_limits())
    is Err(ChecksumMismatch(..)),
  )
}

///|
test "receipt-only delta has an explicit bounded encoding" {
  let delta = @router.DurableDelta::empty()
  let encoded = encode_durable_delta(delta).unwrap()
  assert_eq(decode_durable_delta(encoded, wal_delta_limits()), Ok(delta))
  assert_true(encode_durable_delta(delta, max_bytes=50) is Err(_))
}
