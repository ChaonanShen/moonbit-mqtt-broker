///|
test "C-T31 V5 delta applies atomically and rejects stale retained revision" {
  let base = BrokerState::new(BrokerConfig::new(4, 8, 4).unwrap())
    .export_snapshot_v5(0L, 0L)
    .unwrap()
  let accumulator = DurableAccumulatorV5::new(base)
  let message : SnapshotMessageV5 = {
    topic: "delta/a",
    payload: b"value",
    qos: 1,
    retain: true,
    publisher_client_id: None,
    properties: {
      payload_format: None,
      content_type: None,
      response_topic: None,
      correlation_data: None,
      user_properties: [],
    },
    expiry_clock: None,
  }
  let first : DurableDeltaV5 = {
    ..DurableDeltaV5::empty(),
    id_floors: [{ kind: 6, new_floor: 2L }],
    retained_puts: [
      { expected_revision: 0L, retained: { revision: 1L, message } },
    ],
  }
  assert_eq(accumulator.apply(first), Ok(()))
  assert_eq(accumulator.snapshot().retained.length(), 1)
  let before = accumulator.snapshot()
  let stale : DurableDeltaV5 = {
    ..DurableDeltaV5::empty(),
    retained_puts: [
      { expected_revision: 0L, retained: { revision: 2L, message } },
    ],
  }
  assert_true(accumulator.apply(stale) is Err(_))
  assert_eq(accumulator.snapshot(), before)
}
