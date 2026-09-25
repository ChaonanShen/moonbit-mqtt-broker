///|
async test "C-T31 V5 WAL bootstrap publishes schema6 authority" {
  with_wal_store_dir("v5-bootstrap", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let checkpoint : WalCheckpointV5 = {
      generation: 1L,
      lsn: 0L,
      identities: [],
      required_features: feature_mqtt5_model,
      policy: None,
      snapshot: v5_empty_snapshot(),
    }
    let wal = WalStore::bootstrap_v5(lock, checkpoint).unwrap()
    let manifest_bytes = @fs.read_file(path + "/broker.manifest").binary()
    assert_eq(
      decode_wal_manifest_v5(manifest_bytes).unwrap().required_features,
      feature_mqtt5_model,
    )
    let header_bytes = @fs.read_file(path + "/wal-1.log").binary()
    assert_eq(
      decode_wal_segment_header(header_bytes).unwrap().logical_schema,
      mqtt5_wal_logical_schema,
    )
    let delta = encode_durable_delta_v5(@router.DurableDeltaV5::empty()).unwrap()
    assert_eq(
      wal.append_batch({ previous_lsn: 0L, transactions: [{ lsn: 1L, delta }] }),
      Ok(1L),
    )
    wal.close()
    let reopened = SnapshotStore::open(config).unwrap()
    let limits = SnapshotDecodeLimits::new(
      @router.BrokerConfig::new(4, 16, 8, max_sessions=8).unwrap(),
      1024,
    ).unwrap()
    let (recovered, state) = WalStore::recover_state_v5(
      reopened,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(state.committed_lsn(), 1L)
    assert_true(state.state().uses_v5_storage())
    recovered.close()
  })
}

///|
async test "C-T31 V5 checkpoint publication keeps LSN and new authority" {
  with_wal_store_dir("v5-checkpoint", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let checkpoint : WalCheckpointV5 = {
      generation: 1L,
      lsn: 0L,
      identities: [],
      required_features: feature_mqtt5_model,
      policy: None,
      snapshot: v5_empty_snapshot(),
    }
    let wal = WalStore::bootstrap_v5(lock, checkpoint).unwrap()
    let delta = encode_durable_delta_v5(@router.DurableDeltaV5::empty()).unwrap()
    assert_eq(
      wal.append_batch({ previous_lsn: 0L, transactions: [{ lsn: 1L, delta }] }),
      Ok(1L),
    )
    assert_eq(
      wal.publish_checkpoint_v5({ ..checkpoint, generation: 2L, lsn: 1L }),
      Ok(()),
    )
    wal.close()
    let reopened = SnapshotStore::open(config).unwrap()
    let limits = SnapshotDecodeLimits::new(
      @router.BrokerConfig::new(4, 16, 8, max_sessions=8).unwrap(),
      1024,
    ).unwrap()
    let (recovered, state) = WalStore::recover_state_v5(
      reopened,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(state.committed_lsn(), 1L)
    assert_eq(recovered.manifest().checkpoint_generation, 2L)
    recovered.close()
  })
}

///|
async test "C-T31 V3 strict migration publishes one V5 authority" {
  with_wal_store_dir("v5-migration", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let wal = WalStore::bootstrap(lock, wal_store_empty_checkpoint()).unwrap()
    let old_delta = encode_durable_delta(@router.DurableDelta::empty()).unwrap()
    assert_eq(
      wal.append_batch({
        previous_lsn: 0L,
        transactions: [{ lsn: 1L, delta: old_delta }],
      }),
      Ok(1L),
    )
    let snapshot = convert_v3_snapshot_to_v5(empty_snapshot()).unwrap()
    assert_eq(wal.migrate_to_v5(snapshot, []), Ok(()))
    assert_eq(wal.manifest().checkpoint_lsn, 1L)
    wal.close()
    let reopened = SnapshotStore::open(config).unwrap()
    let limits = SnapshotDecodeLimits::new(
      @router.BrokerConfig::new(4, 16, 8, max_sessions=8).unwrap(),
      1024,
    ).unwrap()
    let (recovered, state) = WalStore::recover_state_v5(
      reopened,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(state.committed_lsn(), 1L)
    assert_true(state.state().uses_v5_storage())
    recovered.close()
  })
}

///|
async test "C-T31 V5 manifest capability can advance beyond old checkpoint" {
  with_wal_store_dir("v5-policy-capability", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let checkpoint : WalCheckpointV5 = {
      generation: 1L,
      lsn: 0L,
      identities: [],
      required_features: feature_mqtt5_model,
      policy: None,
      snapshot: v5_empty_snapshot(),
    }
    let wal = WalStore::bootstrap_v5(lock, checkpoint).unwrap()
    assert_eq(wal.require_policy_capability(), Ok(()))
    wal.close()
    let reopened = SnapshotStore::open(config).unwrap()
    let limits = SnapshotDecodeLimits::new(
      @router.BrokerConfig::new(4, 16, 8, max_sessions=8).unwrap(),
      1024,
    ).unwrap()
    let (recovered, state) = WalStore::recover_state_v5(
      reopened,
      limits.broker_config(),
      limits,
    ).unwrap()
    assert_eq(state.committed_lsn(), 0L)
    assert_true(state.policy_required())
    recovered.close()
  })
}
