///|
async fn with_wal_store_dir(
  name : String,
  body : async (String) -> Unit,
) -> Unit {
  let path = "_build/wal-store-" + name
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  body(path)
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}

///|
fn wal_store_empty_checkpoint() -> WalCheckpoint {
  {
    generation: 1L,
    lsn: 0L,
    identities: [],
    snapshot: { version: 3, sessions: [], retained: [] },
  }
}

///|
fn wal_store_limits() -> SnapshotDecodeLimits {
  SnapshotDecodeLimits::new(
    @router.BrokerConfig::new(4, 16, 8, max_sessions=8).unwrap(),
    1024,
  ).unwrap()
}

///|
async test "WAL store bootstraps appends and recovers a committed batch" {
  with_wal_store_dir("roundtrip", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(lock, wal_store_empty_checkpoint()).unwrap()
    let batch : WalBatch = {
      previous_lsn: 0L,
      transactions: [{ lsn: 1L, delta: b"durable-delta" }],
    }
    assert_eq(wal.append_batch(batch), Ok(1L))
    wal.close()
    let second = SnapshotStore::open(config).unwrap()
    let (recovered, replay) = WalStore::recover(second, wal_store_limits()).unwrap()
    assert_eq(replay.committed_lsn(), 1L)
    assert_eq(replay.batches(), [batch])
    assert_false(replay.recovered_tail())
    recovered.close()
  })
}

///|
async test "WAL store truncates only incomplete active tail and recovers twice" {
  with_wal_store_dir("tail", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let first = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(first, wal_store_empty_checkpoint()).unwrap()
    let batch : WalBatch = {
      previous_lsn: 0L,
      transactions: [{ lsn: 1L, delta: b"value" }],
    }
    assert_eq(wal.append_batch(batch), Ok(1L))
    wal.close()
    let active_path = path + "/wal-1.log"
    let tail = @fs.open(
      active_path,
      mode=WriteOnly,
      create_mode=OpenExisting,
      append=true,
    )
    tail.write(b"\x01\x00\x00")
    tail.close()
    let second = SnapshotStore::open(config).unwrap()
    let (recovered, replay) = WalStore::recover(second, wal_store_limits()).unwrap()
    assert_eq(replay.committed_lsn(), 1L)
    assert_true(replay.recovered_tail())
    recovered.close()
    let third = SnapshotStore::open(config).unwrap()
    let (recovered_again, replay_again) = WalStore::recover(
      third,
      wal_store_limits(),
    ).unwrap()
    assert_eq(replay_again.committed_lsn(), 1L)
    assert_false(replay_again.recovered_tail())
    recovered_again.close()
  })
}

///|
async test "WAL store rotates only at committed batch boundary" {
  with_wal_store_dir("rotation", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let first = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(first, wal_store_empty_checkpoint()).unwrap()
    let a : WalBatch = {
      previous_lsn: 0L,
      transactions: [{ lsn: 1L, delta: b"first" }],
    }
    let b : WalBatch = {
      previous_lsn: 1L,
      transactions: [{ lsn: 2L, delta: b"next" }],
    }
    assert_eq(wal.append_batch(a, max_segment_bytes=150), Ok(1L))
    assert_eq(wal.append_batch(b, max_segment_bytes=150), Ok(2L))
    assert_eq(wal.manifest().sealed_segments.length(), 1)
    assert_eq(wal.manifest().active_segment_id, 2L)
    wal.close()
    let second = SnapshotStore::open(config).unwrap()
    let (recovered, replay) = WalStore::recover(
      second,
      wal_store_limits(),
      max_segment_bytes=150,
    ).unwrap()
    assert_eq(replay.committed_lsn(), 2L)
    assert_eq(replay.batches(), [a, b])
    recovered.close()
  })
}

///|
async test "WAL store rejects a complete corrupt active frame without truncation" {
  with_wal_store_dir("corrupt", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let first = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(first, wal_store_empty_checkpoint()).unwrap()
    let batch : WalBatch = {
      previous_lsn: 0L,
      transactions: [{ lsn: 1L, delta: b"value" }],
    }
    assert_eq(wal.append_batch(batch), Ok(1L))
    wal.close()
    let active_path = path + "/wal-1.log"
    let bytes = @fs.read_file(active_path).binary().to_array()
    bytes[40 + 5 + 8 + 4] = bytes[40 + 5 + 8 + 4] ^ 1
    let damaged = Bytes::from_array(bytes)
    @fs.write_file(active_path, damaged, create_mode=TruncateExisting)
    let second = SnapshotStore::open(config).unwrap()
    assert_true(
      WalStore::recover(second, wal_store_limits()) is Err(ChecksumMismatch(..)),
    )
    second.close()
    assert_eq(@fs.read_file(active_path).binary(), damaged)
  })
}
