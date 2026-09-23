///|
fn wal_scan_fixture() -> (Bytes, Int, Int64) {
  let header = encode_wal_segment_header({
    segment_id: 1L,
    first_lsn: 1L,
    previous_lsn: 0L,
    logical_schema: 3,
  }).unwrap()
  let batch = encode_wal_batch({
    previous_lsn: 0L,
    transactions: [{ lsn: 1L, delta: b"first" }],
  }).unwrap()
  let bytes = header.to_array()
  for byte in batch {
    bytes.push(byte)
  }
  (Bytes::from_array(bytes), batch.length(), 1L)
}

///|
test "active WAL scan accepts committed batches and trims only incomplete tail" {
  let (valid, batch_length, _) = wal_scan_fixture()
  let clean = scan_wal_segment(valid, true).unwrap()
  assert_eq(clean.committed_lsn, 1L)
  assert_eq(clean.committed_bytes, 40 + batch_length)
  assert_false(clean.recovered_tail)
  let bytes = valid.to_array()
  bytes.push(1)
  bytes.push(0)
  bytes.push(0)
  let tailed = Bytes::from_array(bytes)
  let recovered = scan_wal_segment(tailed, true).unwrap()
  assert_eq(recovered.committed_bytes, valid.length())
  assert_eq(recovered.committed_lsn, 1L)
  assert_true(recovered.recovered_tail)
  assert_true(scan_wal_segment(tailed, false) is Err(InvalidValue(..)))
}

///|
test "active WAL scan discards complete uncommitted transaction" {
  let (valid, _, _) = wal_scan_fixture()
  let first_transaction_bytes = 1 + 4 + 8 + 4 + 5 + 4
  let uncommitted = valid[:40 + first_transaction_bytes].to_owned()
  let scan = scan_wal_segment(uncommitted, true).unwrap()
  assert_eq(scan.committed_bytes, 40)
  assert_eq(scan.committed_lsn, 0L)
  assert_true(scan.recovered_tail)
  assert_true(scan_wal_segment(uncommitted, false) is Err(InvalidValue(..)))
}

///|
test "complete CRC-corrupt WAL frame is never treated as active tail" {
  let (valid, _, _) = wal_scan_fixture()
  let changed = valid.to_array()
  changed[40 + 5 + 8 + 4] = changed[40 + 5 + 8 + 4] ^ 1
  assert_true(
    scan_wal_segment(Bytes::from_array(changed), true)
    is Err(ChecksumMismatch(..)),
  )
}
