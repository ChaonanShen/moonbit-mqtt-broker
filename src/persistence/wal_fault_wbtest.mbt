///|
async fn with_wal_fault_dir(
  name : String,
  body : async (String) -> Unit,
) -> Unit {
  let path = "_build/wal-fault-" + name
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  body(path)
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}

///|
fn wal_fault_checkpoint() -> WalCheckpoint {
  {
    generation: 1L,
    lsn: 0L,
    identities: [],
    snapshot: { version: 3, sessions: [], retained: [] },
  }
}

///|
fn wal_fault_limits() -> SnapshotDecodeLimits {
  SnapshotDecodeLimits::new(@router.BrokerConfig::new(4, 16, 8).unwrap(), 1024).unwrap()
}

///|
fn wal_fault_batch() -> WalBatch {
  {
    previous_lsn: 0L,
    transactions: [
      {
        lsn: 1L,
        delta: encode_durable_delta(@router.DurableDelta::empty()).unwrap(),
      },
    ],
  }
}

///|
async test "partial transaction tail is trimmed once before strict recovery" {
  with_wal_fault_dir("partial", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(lock, wal_fault_checkpoint()).unwrap()
    wal.fault = Some(AppendPartialTransaction)
    assert_true(wal.append_batch(wal_fault_batch()) is Err(FileSystem(..)))
    assert_true(wal.is_fenced())
    wal.close()
    let second = SnapshotStore::open(config).unwrap()
    let (restored, replay) = WalStore::recover(second, wal_fault_limits()).unwrap()
    assert_eq(replay.committed_lsn(), 0L)
    assert_true(replay.recovered_tail())
    restored.close()
    let third = SnapshotStore::open(config).unwrap()
    let (again, replay_again) = WalStore::recover(third, wal_fault_limits()).unwrap()
    assert_false(replay_again.recovered_tail())
    again.close()
  })
}

///|
async test "post-fsync error fences old process but complete commit replays" {
  with_wal_fault_dir("after-sync", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(lock, wal_fault_checkpoint()).unwrap()
    wal.fault = Some(AppendAfterSync)
    assert_true(wal.append_batch(wal_fault_batch()) is Err(FileSystem(..)))
    assert_true(wal.is_fenced())
    wal.close()
    let second = SnapshotStore::open(config).unwrap()
    let limits = wal_fault_limits()
    let (restored, replay) = WalStore::recover_state(
      second,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(replay.committed_lsn(), 1L)
    restored.close()
  })
}

///|
async test "post-publication checkpoint GC failure is degraded and recoverable" {
  with_wal_fault_dir("gc", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(lock, wal_fault_checkpoint()).unwrap()
    assert_eq(wal.append_batch(wal_fault_batch()), Ok(1L))
    wal.fault = Some(CheckpointBeforeGc)
    let checkpoint : WalCheckpoint = {
      ..wal_fault_checkpoint(),
      generation: 2L,
      lsn: 1L,
    }
    assert_true(wal.publish_checkpoint(checkpoint) is Err(FileSystem(..)))
    assert_false(wal.is_fenced())
    assert_eq(wal.manifest().checkpoint_lsn, 1L)
    wal.close()
    let second = SnapshotStore::open(config).unwrap()
    let limits = wal_fault_limits()
    let (restored, replay) = WalStore::recover_state(
      second,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(replay.committed_lsn(), 1L)
    restored.close()
  })
}

///|
async test "manifest rename uncertainty fences rotation and retains a recoverable chain" {
  with_wal_fault_dir("rotate-rename", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(lock, wal_fault_checkpoint()).unwrap()
    assert_eq(wal.append_batch(wal_fault_batch()), Ok(1L))
    wal.fault = Some(RotateAfterManifestRename)
    assert_true(wal.rotate() is Err(FileSystem(..)))
    assert_true(wal.is_fenced())
    wal.close()
    let second = SnapshotStore::open(config).unwrap()
    let limits = wal_fault_limits()
    let (restored, replay) = WalStore::recover_state(
      second,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(replay.committed_lsn(), 1L)
    restored.close()
  })
}

///|
async test "checkpoint manifest rename uncertainty fences without deleting old chain" {
  with_wal_fault_dir("checkpoint-rename", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(lock, wal_fault_checkpoint()).unwrap()
    assert_eq(wal.append_batch(wal_fault_batch()), Ok(1L))
    wal.fault = Some(CheckpointAfterManifestRename)
    let checkpoint : WalCheckpoint = {
      ..wal_fault_checkpoint(),
      generation: 2L,
      lsn: 1L,
    }
    assert_true(
      wal.publish_checkpoint(checkpoint) is Err(DurabilityUncertain(_)),
    )
    assert_true(wal.is_fenced())
    assert_true(@fs.exists(path + "/wal-1.log"))
    wal.close()
    let second = SnapshotStore::open(config).unwrap()
    let limits = wal_fault_limits()
    let (restored, replay) = WalStore::recover_state(
      second,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(replay.committed_lsn(), 1L)
    restored.close()
  })
}

///|
async test "checkpoint slice preempts for WAL work without publishing partial manifest" {
  with_wal_fault_dir("checkpoint-preempt", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(lock, wal_fault_checkpoint()).unwrap()
    assert_eq(wal.append_batch(wal_fault_batch()), Ok(1L))
    let large = Bytes::make(2097152, b'x')
    let checkpoint : WalCheckpoint = {
      generation: 2L,
      lsn: 1L,
      identities: [],
      snapshot: {
        version: 3,
        sessions: [],
        retained: [{ topic: "large", payload: large, qos: 1 }],
      },
    }
    let mut slices = 0
    let result = wal.publish_checkpoint(checkpoint, preempt=() => {
      slices += 1
      slices >= 2
    })
    assert_true(
      result is Err(FileSystem(operation="wal-checkpoint-preempted", ..)),
    )
    assert_false(wal.is_fenced())
    assert_eq(wal.manifest().checkpoint_lsn, 0L)
    assert_false(@fs.exists(path + "/checkpoint-2.snap"))
    assert_eq(
      wal.append_batch({
        previous_lsn: 1L,
        transactions: [
          {
            lsn: 2L,
            delta: encode_durable_delta(@router.DurableDelta::empty()).unwrap(),
          },
        ],
      }),
      Ok(2L),
    )
    wal.close()
    let second = SnapshotStore::open(config).unwrap()
    let limits = wal_fault_limits()
    let (recovered, replay) = WalStore::recover_state(
      second,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(replay.committed_lsn(), 2L)
    recovered.close()
  })
}
