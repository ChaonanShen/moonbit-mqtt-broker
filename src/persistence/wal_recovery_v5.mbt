///|
fn replay_v5_batches(
  accumulator : @router.DurableAccumulatorV5,
  batches : Array[WalBatch],
  starting_lsn : Int64,
  starting_policy : WalPolicyState?,
  policy_required : Bool,
  limits : SnapshotDecodeLimits,
) -> Result[(Int64, WalPolicyState?), PersistenceError] {
  let mut lsn = starting_lsn
  let mut policy = starting_policy
  for batch in batches {
    if batch.previous_lsn != lsn {
      return Err(wal_corrupt("v5-batch-chain", 0))
    }
    for transaction in batch.transactions {
      if lsn == 9223372036854775807L || transaction.lsn != lsn + 1L {
        return Err(wal_corrupt("v5-transaction-chain", 0))
      }
      if is_wal_policy_record(transaction.delta) {
        if !policy_required {
          return Err(wal_corrupt("v5-policy-capability", 0))
        }
        let record = match decode_wal_policy_record(transaction.delta) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        policy = match apply_policy_record(policy, record) {
          Ok(value) => Some(value)
          Err(error) => return Err(error)
        }
      } else if is_wal_reconcile_record(transaction.delta) {
        return Err(wal_corrupt("v5-reconcile-unavailable", 0))
      } else {
        let delta = match decode_durable_delta_v5(transaction.delta, limits) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if accumulator.apply(delta) is Err(_) {
          return Err(SnapshotImport("V5 WAL delta conflicts with authority"))
        }
      }
      lsn = transaction.lsn
    }
  }
  Ok((lsn, policy))
}

///|
pub async fn WalStore::recover_state_v5(
  snapshot_store : SnapshotStore,
  broker_config : @router.BrokerConfig,
  limits : SnapshotDecodeLimits,
  max_segment_bytes? : Int = 67108864,
  disk_max_bytes? : Int64 = 1073741824L,
  disk_reserve_bytes? : Int64 = 268435456L,
) -> Result[(WalStore, WalRecoveredState), PersistenceError] {
  let dir = snapshot_store.data_dir()
  if broker_config != limits.broker_config() ||
    !valid_wal_disk_limits(disk_max_bytes, disk_reserve_bytes) {
    return Err(InvalidConfiguration("invalid V5 WAL recovery configuration"))
  }
  try {
    let manifest = match
      decode_wal_manifest_v5(
        bounded_read_regular(dir + "/" + wal_manifest_name, 32768),
      ) {
      Ok(value) => value
      Err(error) => raise error
    }
    let checkpoint = match
      decode_wal_checkpoint_v5(
        bounded_read_regular(
          dir + "/" + wal_checkpoint_name(manifest.checkpoint_generation),
          134217728,
        ),
        limits,
      ) {
      Ok(value) => value
      Err(error) => raise error
    }
    if checkpoint.generation != manifest.checkpoint_generation ||
      checkpoint.lsn != manifest.checkpoint_lsn ||
      (checkpoint.required_features & manifest.required_features) !=
      checkpoint.required_features {
      raise wal_corrupt("v5-checkpoint-manifest-mismatch", 0)
    }
    let accumulator = @router.DurableAccumulatorV5::new(checkpoint.snapshot)
    let mut previous_lsn = checkpoint.lsn
    let mut policy = checkpoint.policy
    for segment in manifest.sealed_segments {
      let scan = match
        scan_wal_segment(
          bounded_read_regular(
            dir + "/" + wal_segment_name(segment.segment_id),
            max_segment_bytes,
          ),
          false,
          max_segment_bytes~,
        ) {
        Ok(value) => value
        Err(error) => raise error
      }
      if scan.header.logical_schema != mqtt5_wal_logical_schema ||
        scan.header.segment_id != segment.segment_id ||
        scan.header.first_lsn != segment.start_lsn ||
        scan.header.previous_lsn != previous_lsn ||
        scan.committed_lsn != segment.end_lsn {
        raise wal_corrupt("v5-sealed-manifest-mismatch", 0)
      }
      let (lsn, next_policy) = match
        replay_v5_batches(
          accumulator,
          scan.batches,
          previous_lsn,
          policy,
          (manifest.required_features & feature_policy_gate) != 0U,
          limits,
        ) {
        Ok(value) => value
        Err(error) => raise error
      }
      previous_lsn = lsn
      policy = next_policy
    }
    let active_path = dir + "/" + wal_segment_name(manifest.active_segment_id)
    let active_bytes = bounded_read_regular(active_path, max_segment_bytes)
    let scan = match scan_wal_segment(active_bytes, true, max_segment_bytes~) {
      Ok(value) => value
      Err(error) => raise error
    }
    if scan.header.logical_schema != mqtt5_wal_logical_schema ||
      scan.header.segment_id != manifest.active_segment_id ||
      scan.header.first_lsn != manifest.active_start_lsn ||
      scan.header.previous_lsn != previous_lsn {
      raise wal_corrupt("v5-active-manifest-mismatch", 0)
    }
    let (committed_lsn, policy) = match
      replay_v5_batches(
        accumulator,
        scan.batches,
        previous_lsn,
        policy,
        (manifest.required_features & feature_policy_gate) != 0U,
        limits,
      ) {
      Ok(value) => value
      Err(error) => raise error
    }
    if committed_lsn != scan.committed_lsn {
      raise wal_corrupt("v5-replay-lsn", 0)
    }
    if scan.recovered_tail {
      match
        truncate_regular_tail(
          active_path,
          active_bytes.length().to_int64(),
          scan.committed_bytes.to_int64(),
        ) {
        Ok(_) => ()
        Err(error) => raise error
      }
    }
    let snapshot = accumulator.snapshot()
    let identities = snapshot.sessions.map(session => WalSessionIdentity::{
      client_id: session.client_id,
      generation: session.incarnation,
    })
    let state = match
      @router.BrokerState::from_snapshot_v5(
        broker_config,
        snapshot,
        @budget.monotonic_ms(),
        @async.now(),
        recover_armed_wills=false,
      ) {
      Ok(value) => value
      Err(_) => raise SnapshotImport("V5 WAL state exceeds limits")
    }
    let active_file = @fs.open(
      active_path,
      mode=WriteOnly,
      create_mode=OpenExisting,
      append=true,
    ) catch {
      _ => raise FileSystem(operation="wal-open-active", path=active_path)
    }
    let disk_bytes = wal_disk_usage(dir)
    if disk_bytes > disk_max_bytes - disk_reserve_bytes {
      active_file.close()
      raise LimitExceeded(
        resource="wal-disk-bytes",
        actual=disk_bytes,
        limit=disk_max_bytes - disk_reserve_bytes,
      )
    }
    let legacy_manifest : WalManifest = {
      generation: manifest.generation,
      checkpoint_generation: manifest.checkpoint_generation,
      checkpoint_lsn: manifest.checkpoint_lsn,
      sealed_segments: manifest.sealed_segments,
      active_segment_id: manifest.active_segment_id,
      active_start_lsn: manifest.active_start_lsn,
      policy_required: (manifest.required_features & feature_policy_gate) != 0U,
    }
    Ok(
      (
        {
          snapshot_store,
          manifest: legacy_manifest,
          manifest_v5: Some(manifest),
          active_file,
          active_path,
          active_bytes: scan.committed_bytes.to_int64(),
          disk_bytes,
          disk_max_bytes,
          disk_reserve_bytes,
          disk_dirty: false,
          fault: None,
          committed_lsn,
          policy_state: policy,
          fenced: false,
          closed: false,
        },
        {
          state,
          identities,
          policy,
          policy_required: legacy_manifest.policy_required,
          committed_lsn,
        },
      ),
    )
  } catch {
    error => Err(error)
  }
}
