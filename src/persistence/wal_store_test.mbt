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

///|
async test "WAL recovery replays committed state result without routing" {
  with_wal_store_dir("replay", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let first = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(first, wal_store_empty_checkpoint()).unwrap()
    let delta : @router.DurableDelta = {
      session_puts: [
        {
          expected_generation: 0L,
          generation: 1L,
          session: {
            client_id: "client-a",
            owner_principal: "anonymous",
            detached_at_ms: 0L,
            next_packet_id: 1,
            subscriptions: [{ filter: "state/#", qos: 1 }],
            inbound_qos2: [],
            inflight: [],
            pending: [],
          },
        },
      ],
      session_deletes: [],
      retained_puts: [{ topic: "state/value", payload: b"ready", qos: 1 }],
      retained_deletes: [],
    }
    let encoded = encode_durable_delta(delta).unwrap()
    assert_eq(
      wal.append_batch({
        previous_lsn: 0L,
        transactions: [{ lsn: 1L, delta: encoded }],
      }),
      Ok(1L),
    )
    wal.close()
    let second = SnapshotStore::open(config).unwrap()
    let limits = wal_store_limits()
    let (recovered, replay) = WalStore::recover(second, limits).unwrap()
    let restored = replay.restore_state(limits.broker_config(), limits).unwrap()
    assert_eq(restored.committed_lsn(), 1L)
    assert_eq(restored.identities(), [{ client_id: "client-a", generation: 1L }])
    let snapshot = restored.state().export_snapshot()
    assert_eq(snapshot.sessions.length(), 1)
    assert_eq(snapshot.sessions[0].subscriptions[0].filter, "state/#")
    assert_eq(snapshot.retained[0].payload, b"ready")
    recovered.close()
  })
}

///|
async test "WAL checkpoint publication retains only the active post-checkpoint chain" {
  with_wal_store_dir("checkpoint", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let first = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(first, wal_store_empty_checkpoint()).unwrap()
    let empty_delta = encode_durable_delta(@router.DurableDelta::empty()).unwrap()
    assert_eq(
      wal.append_batch({
        previous_lsn: 0L,
        transactions: [{ lsn: 1L, delta: empty_delta }],
      }),
      Ok(1L),
    )
    let checkpoint : WalCheckpoint = {
      ..wal_store_empty_checkpoint(),
      generation: 2L,
      lsn: 1L,
    }
    assert_eq(wal.publish_checkpoint(checkpoint), Ok(()))
    assert_eq(wal.manifest().checkpoint_lsn, 1L)
    assert_eq(wal.manifest().sealed_segments.length(), 0)
    assert_false(@fs.exists(path + "/checkpoint-1.snap"))
    assert_false(@fs.exists(path + "/wal-1.log"))
    assert_eq(
      wal.append_batch({
        previous_lsn: 1L,
        transactions: [{ lsn: 2L, delta: empty_delta }],
      }),
      Ok(2L),
    )
    wal.close()
    let second = SnapshotStore::open(config).unwrap()
    let limits = wal_store_limits()
    let (recovered, replay) = WalStore::recover(second, limits).unwrap()
    assert_eq(replay.checkpoint().lsn, 1L)
    assert_eq(replay.committed_lsn(), 2L)
    assert_eq(replay.batches().length(), 1)
    assert_eq(
      replay
      .restore_state(limits.broker_config(), limits)
      .unwrap()
      .committed_lsn(),
      2L,
    )
    recovered.close()
  })
}

///|
async test "WAL disk cap includes unreferenced sparse orphan files" {
  with_wal_store_dir("orphan-cap", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let first = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(first, wal_store_empty_checkpoint()).unwrap()
    wal.close()
    let orphan = @fs.open(
      path + "/wal-999.log",
      mode=WriteOnly,
      create_mode=CreateNew,
      permission=0o600,
    )
    orphan.write_at(b"x", position=940000000L)
    orphan.sync(only_data=false)
    orphan.close()
    let second = SnapshotStore::open(config).unwrap()
    assert_true(
      WalStore::recover(second, wal_store_limits()) is Err(LimitExceeded(..)),
    )
    second.close()
  })
}

///|
async test "streaming WAL recovery applies multiple segments without retaining history" {
  with_wal_store_dir("stream-replay", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(lock, wal_store_empty_checkpoint()).unwrap()
    for lsn in 1..<=4 {
      let delta : @router.DurableDelta = {
        session_puts: [],
        session_deletes: [],
        retained_puts: [
          { topic: "value/" + lsn.to_string(), payload: b"x", qos: 1 },
        ],
        retained_deletes: [],
      }
      assert_eq(
        wal.append_batch(
          {
            previous_lsn: lsn.to_int64() - 1L,
            transactions: [
              {
                lsn: lsn.to_int64(),
                delta: encode_durable_delta(delta).unwrap(),
              },
            ],
          },
          max_segment_bytes=512,
        ),
        Ok(lsn.to_int64()),
      )
    }
    assert_true(wal.manifest().sealed_segments.length() > 0)
    wal.close()
    let second = SnapshotStore::open(config).unwrap()
    let limits = wal_store_limits()
    let (recovered, restored) = WalStore::recover_state(
      second,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(restored.committed_lsn(), 4L)
    assert_eq(restored.state().retained_count(), 4)
    recovered.close()
  })
}
