///|
test "C-T30 empty MQTT5 WAL delta has independent golden bytes" {
  let delta = @router.DurableDeltaV5::empty()
  let encoded = encode_durable_delta_v5(delta).unwrap()
  let golden = v5_test_hex(
    "4d424d444c54303100020006000000000000000000000000000000000000000000000000000000000000000000000000000ca8d4ae",
  )
  assert_eq(encoded, golden)
  let limits = SnapshotDecodeLimits::new(
    @router.BrokerConfig::new(10, 10, 10).unwrap(),
    1024,
  ).unwrap()
  assert_eq(decode_durable_delta_v5(golden, limits), Ok(delta))
}

///|
test "C-T30 MQTT5 WAL delta rejects duplicate high-water kinds and bad CRC" {
  let delta : @router.DurableDeltaV5 = {
    ..@router.DurableDeltaV5::empty(),
    id_floors: [{ kind: 3, new_floor: 7L }],
    retained_deletes: [{ topic: "old/a", expected_revision: 1L }],
  }
  let limits = SnapshotDecodeLimits::new(
    @router.BrokerConfig::new(10, 10, 10).unwrap(),
    1024,
  ).unwrap()
  let encoded = encode_durable_delta_v5(delta).unwrap()
  assert_eq(decode_durable_delta_v5(encoded, limits), Ok(delta))
  assert_true(
    encode_durable_delta_v5({
      ..delta,
      id_floors: [{ kind: 3, new_floor: 7L }, { kind: 3, new_floor: 8L }],
    })
    is Err(_),
  )
  let bytes = encoded.to_array()
  bytes[bytes.length() - 1] = 0
  assert_true(
    decode_durable_delta_v5(Bytes::from_array(bytes), limits)
    is Err(ChecksumMismatch(..)),
  )
}
