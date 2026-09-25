///|
fn v5_fault_snapshot() -> @router.BrokerSnapshotV5 {
  convert_v3_snapshot_to_v5({ version: 3, sessions: [], retained: [] }).unwrap()
}

///|
async test "C-T31 failed schema6 migration before authority switch keeps V3" {
  with_wal_fault_dir("v5-migrate-before-create", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(lock, wal_fault_checkpoint()).unwrap()
    wal.fault = Some(CheckpointBeforeCreate)
    assert_true(
      wal.migrate_to_v5(v5_fault_snapshot(), []) is Err(FileSystem(..)),
    )
    assert_false(wal.uses_v5_schema())
    assert_false(wal.is_fenced())
    wal.close()
    let reopened = SnapshotStore::open(config).unwrap()
    let limits = wal_fault_limits()
    let (old, state) = WalStore::recover_state(
      reopened,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(state.committed_lsn(), 0L)
    old.close()
  })
}

///|
async test "C-T31 schema6 manifest rename uncertainty fences but recovers V5" {
  with_wal_fault_dir("v5-migrate-rename", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(lock, wal_fault_checkpoint()).unwrap()
    wal.fault = Some(CheckpointAfterManifestRename)
    assert_true(
      wal.migrate_to_v5(v5_fault_snapshot(), []) is Err(DurabilityUncertain(_)),
    )
    assert_true(wal.is_fenced())
    wal.close()
    let reopened = SnapshotStore::open(config).unwrap()
    let limits = wal_fault_limits()
    let (current, state) = WalStore::recover_state_v5(
      reopened,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(state.committed_lsn(), 0L)
    assert_true(current.uses_v5_schema())
    current.close()
  })
}

///|
async test "C-T31 V5 checkpoint rename uncertainty leaves one recoverable authority" {
  with_wal_fault_dir("v5-checkpoint-rename", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let initial : WalCheckpointV5 = {
      generation: 1L,
      lsn: 0L,
      identities: [],
      required_features: feature_mqtt5_model,
      policy: None,
      snapshot: v5_fault_snapshot(),
    }
    let wal = WalStore::bootstrap_v5(lock, initial).unwrap()
    let delta = encode_durable_delta_v5(@router.DurableDeltaV5::empty()).unwrap()
    assert_eq(
      wal.append_batch({ previous_lsn: 0L, transactions: [{ lsn: 1L, delta }] }),
      Ok(1L),
    )
    wal.fault = Some(CheckpointAfterManifestRename)
    let next : WalCheckpointV5 = { ..initial, generation: 2L, lsn: 1L }
    assert_true(wal.publish_checkpoint_v5(next) is Err(DurabilityUncertain(_)))
    assert_true(wal.is_fenced())
    wal.close()
    let reopened = SnapshotStore::open(config).unwrap()
    let limits = wal_fault_limits()
    let (current, state) = WalStore::recover_state_v5(
      reopened,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(state.committed_lsn(), 1L)
    assert_eq(current.manifest().checkpoint_generation, 2L)
    current.close()
  })
}
