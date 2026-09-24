///|
test "reconcile WAL descriptors round trip without copying payload" {
  let first : @router.DurableReconcileDelta = {
    client_id: "client-a",
    expected_generation: 7L,
    change: @router.DropSubscription("private/#"),
  }
  let second : @router.DurableReconcileDelta = {
    client_id: "client-a",
    expected_generation: 7L,
    change: @router.DropPendingHead("private/data", 1, 1048576),
  }
  let third : @router.DurableReconcileDelta = {
    client_id: "client-a",
    expected_generation: 7L,
    change: @router.DropPendingAt(12, "private/data", 1, 1048576),
  }
  for delta in [first, second, third] {
    let encoded = encode_wal_reconcile(delta).unwrap()
    assert_true(encoded.length() < 256)
    assert_true(decode_wal_reconcile(encoded) == Ok(delta))
    let corrupt = encoded.to_array()
    corrupt[corrupt.length() - 1] = corrupt[corrupt.length() - 1] ^ 1
    assert_true(decode_wal_reconcile(Bytes::from_array(corrupt)) is Err(_))
  }
}
