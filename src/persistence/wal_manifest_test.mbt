///|
fn wal_test_manifest() -> WalManifest {
  {
    generation: 3L,
    checkpoint_generation: 2L,
    checkpoint_lsn: 40L,
    sealed_segments: [
      { segment_id: 5L, start_lsn: 41L, end_lsn: 50L },
      { segment_id: 6L, start_lsn: 51L, end_lsn: 60L },
    ],
    active_segment_id: 7L,
    active_start_lsn: 61L,
    policy_required: false,
  }
}

///|
test "WAL manifest has a checked versioned segment chain" {
  let manifest = wal_test_manifest()
  let first = encode_wal_manifest(manifest).unwrap()
  assert_eq(first, encode_wal_manifest(manifest).unwrap())
  assert_eq(decode_wal_manifest(first), Ok(manifest))
  let changed = first.to_array()
  changed[24] = changed[24] ^ 1
  assert_true(
    decode_wal_manifest(Bytes::from_array(changed)) is Err(ChecksumMismatch(..)),
  )
  assert_true(
    decode_wal_manifest(first[:first.length() - 1].to_owned())
    is Err(Truncated(..)),
  )
}

///|
test "WAL manifest refuses missing and overlapping LSN ranges" {
  let base = wal_test_manifest()
  let gap : WalManifest = {
    ..base,
    sealed_segments: [{ segment_id: 5L, start_lsn: 42L, end_lsn: 50L }],
    active_segment_id: 6L,
    active_start_lsn: 51L,
  }
  assert_true(encode_wal_manifest(gap) is Err(InvalidValue(..)))
  let overlap : WalManifest = { ..base, active_start_lsn: 60L }
  assert_true(encode_wal_manifest(overlap) is Err(InvalidValue(..)))
}

///|
test "WAL manifest v2 advertises required policy capability" {
  let original = wal_test_manifest()
  let policy : WalManifest = { ..original, policy_required: true }
  let bytes = encode_wal_manifest(policy).unwrap()
  assert_eq(decode_wal_manifest(bytes), Ok(policy))
  assert_true(bytes != encode_wal_manifest(original).unwrap())
}
