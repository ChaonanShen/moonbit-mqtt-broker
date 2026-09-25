///|
fn policy_test_fingerprint(value : Byte) -> Bytes {
  let bytes : Array[Byte] = []
  for _ in 0..<32 {
    bytes.push(value)
  }
  Bytes::from_array(bytes)
}

///|
test "policy WAL record round trips and is rejected as business delta" {
  let fingerprint = policy_test_fingerprint(7)
  let activated : WalPolicyRecord = {
    transition: PolicyActivated,
    sequence: 3L,
    fingerprint,
  }
  let encoded = encode_wal_policy_record(activated).unwrap()
  assert_eq(encoded.length(), 57)
  assert_true(decode_wal_policy_record(encoded) == Ok(activated))
  assert_true(
    decode_durable_delta(
      encoded,
      SnapshotDecodeLimits::new(
        @router.BrokerConfig::new(4, 16, 4).unwrap(),
        1048576,
      ).unwrap(),
    )
    is Err(_),
  )
}

///|
test "policy WAL record checks version checksum and bounds" {
  let fingerprint = policy_test_fingerprint(3)
  let reconciled : WalPolicyRecord = {
    transition: PolicyReconciled,
    sequence: 1L,
    fingerprint,
  }
  let encoded = encode_wal_policy_record(reconciled).unwrap()
  let damaged = encoded.to_array()
  damaged[25] = 8
  assert_true(decode_wal_policy_record(Bytes::from_array(damaged)) is Err(_))
  assert_true(
    encode_wal_policy_record({
      transition: PolicyActivated,
      sequence: 0L,
      fingerprint,
    })
    is Err(_),
  )
}
