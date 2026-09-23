///|
fn wal_test_batch() -> WalBatch {
  {
    previous_lsn: 40L,
    transactions: [
      { lsn: 41L, delta: b"session-A" },
      { lsn: 42L, delta: b"retained-B" },
    ],
  }
}

///|
fn wal_replace_byte(data : Bytes, offset : Int, value : Byte) -> Bytes {
  let bytes = data.to_array()
  bytes[offset] = value
  Bytes::from_array(bytes)
}

///|
test "WAL segment header has independent version and checksum" {
  let header : WalSegmentHeader = {
    segment_id: 7L,
    first_lsn: 41L,
    previous_lsn: 40L,
    logical_schema: 3,
  }
  let bytes = encode_wal_segment_header(header).unwrap()
  assert_eq(bytes.length(), 40)
  assert_eq(bytes[:8].to_owned(), b"MBMWAL01")
  assert_eq(decode_wal_segment_header(bytes), Ok(header))
  assert_true(
    decode_wal_segment_header(wal_replace_byte(bytes, 20, bytes[20] ^ 1))
    is Err(ChecksumMismatch(..)),
  )
  assert_true(
    decode_wal_segment_header(bytes[:39].to_owned()) is Err(Truncated(..)),
  )
}

///|
test "WAL batch frames are deterministic and commit exactly consecutive LSNs" {
  let batch = wal_test_batch()
  let first = encode_wal_batch(batch).unwrap()
  let second = encode_wal_batch(batch).unwrap()
  assert_eq(first, second)
  assert_eq(decode_wal_batch(first, 40L), Ok(batch))
  assert_true(decode_wal_batch(first, 39L) is Err(InvalidValue(..)))
  let corrupt = wal_replace_byte(first, 20, first[20] ^ 1)
  assert_true(decode_wal_batch(corrupt, 40L) is Err(ChecksumMismatch(..)))
  assert_true(
    decode_wal_batch(first[:first.length() - 1].to_owned(), 40L)
    is Err(Truncated(..)),
  )
}

///|
test "WAL encoder rejects gaps and bounded payload overflow" {
  let missing : WalBatch = {
    previous_lsn: 40L,
    transactions: [{ lsn: 42L, delta: b"a" }],
  }
  assert_true(encode_wal_batch(missing) is Err(InvalidValue(..)))
  let oversized : WalBatch = {
    previous_lsn: 0L,
    transactions: [{ lsn: 1L, delta: b"long" }],
  }
  assert_true(
    encode_wal_batch(oversized, max_transaction_bytes=3)
    is Err(InvalidValue(..)),
  )
}
