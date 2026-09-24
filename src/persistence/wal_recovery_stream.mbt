///|
fn replay_wal_batches(
  accumulator : @router.DurableAccumulator,
  batches : Array[WalBatch],
  starting_lsn : Int64,
  starting_policy : WalPolicyState?,
  limits : SnapshotDecodeLimits,
) -> Result[(Int64, WalPolicyState?), PersistenceError] {
  let mut lsn = starting_lsn
  let mut policy = starting_policy
  for batch in batches {
    if batch.previous_lsn != lsn {
      return Err(InvalidValue(field="wal-replay-batch-chain", offset=0))
    }
    for transaction in batch.transactions {
      if lsn == 9223372036854775807L || transaction.lsn != lsn + 1L {
        return Err(InvalidValue(field="wal-replay-transaction-chain", offset=0))
      }
      if is_wal_policy_record(transaction.delta) {
        let record = match decode_wal_policy_record(transaction.delta) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        policy = match apply_policy_record(policy, record) {
          Ok(value) => Some(value)
          Err(error) => return Err(error)
        }
      } else {
        let delta = match decode_durable_delta(transaction.delta, limits) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        match accumulator.apply(delta) {
          Ok(_) => ()
          Err(_) =>
            return Err(SnapshotImport("WAL delta violates state limits"))
        }
      }
      lsn = transaction.lsn
    }
  }
  Ok((lsn, policy))
}

///|
/// Production recovery applies each bounded segment before reading the next
/// one. It does not retain the entire WAL history in memory.
pub async fn WalStore::recover_state(
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
    return Err(InvalidConfiguration("invalid WAL recovery configuration"))
  }
  let manifest_path = dir + "/" + wal_manifest_name
  try {
    let manifest = match
      decode_wal_manifest(bounded_read_regular(manifest_path, 32768)) {
      Ok(value) => value
      Err(error) => raise error
    }
    let checkpoint_path = dir +
      "/" +
      wal_checkpoint_name(manifest.checkpoint_generation)
    let checkpoint = match
      decode_wal_checkpoint(
        bounded_read_regular(checkpoint_path, 134217728),
        limits,
      ) {
      Ok(value) => value
      Err(error) => raise error
    }
    if checkpoint.generation != manifest.checkpoint_generation ||
      checkpoint.lsn != manifest.checkpoint_lsn {
      raise wal_corrupt("checkpoint-manifest-mismatch", 0)
    }
    let generations = checkpoint.identities.map(item => item.generation)
    let accumulator = match
      @router.DurableAccumulator::new(
        broker_config,
        checkpoint.snapshot,
        generations,
      ) {
      Ok(value) => value
      Err(_) => raise SnapshotImport("invalid WAL checkpoint state")
    }
    let mut previous_lsn = checkpoint.lsn
    let mut policy = checkpoint.policy
    for sealed_segment in manifest.sealed_segments {
      let path = dir + "/" + wal_segment_name(sealed_segment.segment_id)
      let scan = match
        scan_wal_segment(
          bounded_read_regular(path, max_segment_bytes),
          false,
          max_segment_bytes~,
        ) {
        Ok(value) => value
        Err(error) => raise error
      }
      if scan.header.segment_id != sealed_segment.segment_id ||
        scan.header.first_lsn != sealed_segment.start_lsn ||
        scan.header.previous_lsn != previous_lsn ||
        scan.committed_lsn != sealed_segment.end_lsn {
        raise wal_corrupt("sealed-manifest-mismatch", 0)
      }
      let (replayed_lsn, replayed_policy) = match
        replay_wal_batches(
          accumulator,
          scan.batches,
          previous_lsn,
          policy,
          limits,
        ) {
        Ok(value) => value
        Err(error) => raise error
      }
      previous_lsn = replayed_lsn
      policy = replayed_policy
    }
    let active_path = dir + "/" + wal_segment_name(manifest.active_segment_id)
    let active_bytes = bounded_read_regular(active_path, max_segment_bytes)
    let scan = match scan_wal_segment(active_bytes, true, max_segment_bytes~) {
      Ok(value) => value
      Err(error) => raise error
    }
    if scan.header.segment_id != manifest.active_segment_id ||
      scan.header.first_lsn != manifest.active_start_lsn ||
      scan.header.previous_lsn != previous_lsn {
      raise wal_corrupt("active-manifest-mismatch", 0)
    }
    let (committed_lsn, policy) = match
      replay_wal_batches(
        accumulator,
        scan.batches,
        previous_lsn,
        policy,
        limits,
      ) {
      Ok(value) => value
      Err(error) => raise error
    }
    if committed_lsn != scan.committed_lsn {
      raise wal_corrupt("active-replay-mismatch", 0)
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
    let (snapshot, generations) = accumulator.export_snapshot()
    let identities : Array[WalSessionIdentity] = []
    for index in 0..<snapshot.sessions.length() {
      identities.push({
        client_id: snapshot.sessions[index].client_id,
        generation: generations[index],
      })
    }
    let state = match
      @router.BrokerState::from_snapshot(broker_config, snapshot) {
      Ok(value) => value
      Err(_) => raise SnapshotImport("WAL state exceeds configured limits")
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
    Ok(
      (
        {
          snapshot_store,
          manifest,
          active_file,
          active_path,
          active_bytes: scan.committed_bytes.to_int64(),
          disk_bytes,
          disk_max_bytes,
          disk_reserve_bytes,
          disk_dirty: false,
          fault: None,
          committed_lsn,
          fenced: false,
          closed: false,
        },
        { state, identities, policy, committed_lsn },
      ),
    )
  } catch {
    error => Err(error)
  }
}
