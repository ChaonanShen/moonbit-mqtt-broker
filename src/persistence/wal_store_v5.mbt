///|
pub async fn WalStore::bootstrap_v5(
  snapshot_store : SnapshotStore,
  checkpoint : WalCheckpointV5,
  disk_max_bytes? : Int64 = 1073741824L,
  disk_reserve_bytes? : Int64 = 268435456L,
) -> Result[WalStore, PersistenceError] {
  let dir = snapshot_store.data_dir()
  if !valid_wal_disk_limits(disk_max_bytes, disk_reserve_bytes) {
    return Err(InvalidConfiguration("invalid WAL disk capacity"))
  }
  let manifest_path = dir + "/" + wal_manifest_name
  let checkpoint_path = dir + "/" + wal_checkpoint_name(checkpoint.generation)
  let active_path = dir + "/" + wal_segment_name(1L)
  let manifest_temp = dir + "/" + wal_manifest_temp_name
  try {
    if checkpoint.generation != 1L ||
      checkpoint.lsn != 0L ||
      wal_exists(manifest_path) ||
      wal_exists(checkpoint_path) ||
      wal_exists(active_path) ||
      wal_exists(manifest_temp) {
      raise InvalidConfiguration("V5 WAL bootstrap requires unused files")
    }
    let checkpoint_bytes = match encode_wal_checkpoint_v5(checkpoint) {
      Ok(value) => value
      Err(error) => raise error
    }
    wal_write_synced_new(checkpoint_path, checkpoint_bytes)
    sync_directory(dir)
    let header = match
      encode_wal_segment_header({
        segment_id: 1L,
        first_lsn: 1L,
        previous_lsn: 0L,
        logical_schema: mqtt5_wal_logical_schema,
      }) {
      Ok(value) => value
      Err(error) => raise error
    }
    wal_write_synced_new(active_path, header)
    sync_directory(dir)
    let manifest_v5 : WalManifestV5 = {
      generation: 1L,
      checkpoint_generation: 1L,
      checkpoint_lsn: 0L,
      sealed_segments: [],
      active_segment_id: 1L,
      active_start_lsn: 1L,
      required_features: checkpoint.required_features,
    }
    let manifest_bytes = match encode_wal_manifest_v5(manifest_v5) {
      Ok(value) => value
      Err(error) => raise error
    }
    wal_write_synced_new(manifest_temp, manifest_bytes)
    @fs.rename(manifest_temp, manifest_path, replace=false) catch {
      _ =>
        raise FileSystem(operation="wal-publish-manifest", path=manifest_path)
    }
    sync_directory(dir)
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
    let manifest : WalManifest = {
      generation: 1L,
      checkpoint_generation: 1L,
      checkpoint_lsn: 0L,
      sealed_segments: [],
      active_segment_id: 1L,
      active_start_lsn: 1L,
      policy_required: checkpoint.policy is Some(_),
    }
    Ok({
      snapshot_store,
      manifest,
      manifest_v5: Some(manifest_v5),
      active_file,
      active_path,
      active_bytes: 40L,
      disk_bytes,
      disk_max_bytes,
      disk_reserve_bytes,
      disk_dirty: false,
      fault: None,
      committed_lsn: 0L,
      policy_state: checkpoint.policy,
      fenced: false,
      closed: false,
    })
  } catch {
    error => Err(error)
  }
}

///|
pub async fn WalStore::publish_checkpoint_v5(
  self : WalStore,
  checkpoint : WalCheckpointV5,
  preempt? : () -> Bool = () => false,
) -> Result[Unit, PersistenceError] {
  let current_v5 = match self.manifest_v5 {
    Some(value) => value
    None =>
      return Err(InvalidConfiguration("V5 checkpoint requires schema6 store"))
  }
  if self.closed ||
    self.fenced ||
    checkpoint.lsn != self.committed_lsn ||
    checkpoint.generation != current_v5.checkpoint_generation + 1L ||
    current_v5.generation == 9223372036854775807L ||
    current_v5.checkpoint_generation == 9223372036854775807L ||
    checkpoint.required_features != current_v5.required_features ||
    checkpoint.policy != self.policy_state {
    return Err(InvalidConfiguration("invalid V5 checkpoint publication"))
  }
  let encoded = match encode_wal_checkpoint_v5(checkpoint) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if preempt() {
    return Err(
      FileSystem(operation="wal-checkpoint-preempted", path="checkpoint"),
    )
  }
  if self.manifest.active_start_lsn <= checkpoint.lsn {
    match self.rotate() {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let dir = self.snapshot_store.data_dir()
  let final_path = dir + "/" + wal_checkpoint_name(checkpoint.generation)
  let temp_path = final_path + ".tmp"
  let manifest_temp = dir + "/" + wal_manifest_temp_name
  let manifest_path = dir + "/" + wal_manifest_name
  let old = self.manifest_v5.unwrap()
  let mut manifest_renamed = false
  let mut manifest_synced = false
  let mut checkpoint_creation_attempted = false
  try {
    if wal_exists(final_path) ||
      wal_exists(temp_path) ||
      wal_exists(manifest_temp) {
      raise InvalidConfiguration("V5 checkpoint found orphan file")
    }
    if self.disk_bytes >
      self.disk_max_bytes - encoded.length().to_int64() - 32768L {
      raise LimitExceeded(
        resource="wal-disk-bytes",
        actual=self.disk_bytes + encoded.length().to_int64() + 32768L,
        limit=self.disk_max_bytes,
      )
    }
    self.fail_if(CheckpointBeforeCreate, "wal-checkpoint-create", temp_path)
    checkpoint_creation_attempted = true
    wal_write_synced_new_preemptible(temp_path, encoded, preempt)
    self.fail_if(CheckpointAfterFileSync, "wal-checkpoint-file-sync", temp_path)
    if preempt() {
      raise FileSystem(operation="wal-checkpoint-preempted", path=temp_path)
    }
    @fs.rename(temp_path, final_path, replace=false) catch {
      _ => raise FileSystem(operation="wal-checkpoint-rename", path=final_path)
    }
    sync_directory(dir)
    if preempt() {
      raise FileSystem(operation="wal-checkpoint-preempted", path=final_path)
    }
    let next : WalManifestV5 = {
      ..old,
      generation: old.generation + 1L,
      checkpoint_generation: checkpoint.generation,
      checkpoint_lsn: checkpoint.lsn,
      sealed_segments: [],
    }
    let manifest_bytes = match encode_wal_manifest_v5(next) {
      Ok(value) => value
      Err(error) => raise error
    }
    wal_write_synced_new(manifest_temp, manifest_bytes)
    @fs.rename(manifest_temp, manifest_path, replace=true) catch {
      _ =>
        raise FileSystem(
          operation="wal-checkpoint-manifest",
          path=manifest_path,
        )
    }
    manifest_renamed = true
    self.fail_if(
      CheckpointAfterManifestRename,
      "wal-checkpoint-after-manifest-rename",
      manifest_path,
    )
    sync_directory(dir)
    manifest_synced = true
    self.manifest_v5 = Some(next)
    self.manifest = {
      ..self.manifest,
      generation: next.generation,
      checkpoint_generation: next.checkpoint_generation,
      checkpoint_lsn: next.checkpoint_lsn,
      sealed_segments: [],
    }
    self.fail_if(CheckpointBeforeGc, "wal-checkpoint-before-gc", manifest_path)
    let old_checkpoint = dir +
      "/" +
      wal_checkpoint_name(old.checkpoint_generation)
    @fs.remove(old_checkpoint) catch {
      _ => ()
    }
    for segment in old.sealed_segments {
      @fs.remove(dir + "/" + wal_segment_name(segment.segment_id)) catch {
        _ => ()
      }
    }
    sync_directory(dir) catch {
      _ => ()
    }
    Ok(())
  } catch {
    error => {
      if checkpoint_creation_attempted && !manifest_renamed {
        best_effort_remove(temp_path)
        best_effort_remove(final_path)
        sync_directory(dir) catch {
          _ => ()
        }
      }
      if manifest_renamed && !manifest_synced {
        self.fenced = true
        Err(DurabilityUncertain(manifest_path))
      } else {
        Err(checkpoint_error(error))
      }
    }
  }
}

///|
pub async fn WalStore::migrate_to_v5(
  self : WalStore,
  snapshot : @router.BrokerSnapshotV5,
  identities : Array[WalSessionIdentity],
) -> Result[Unit, PersistenceError] {
  if self.closed ||
    self.fenced ||
    self.manifest_v5 is Some(_) ||
    self.manifest.checkpoint_generation == 9223372036854775807L ||
    self.manifest.active_segment_id == 9223372036854775807L ||
    self.manifest.generation == 9223372036854775807L {
    return Err(InvalidConfiguration("WAL migration cannot start"))
  }
  let old = self.manifest
  let checkpoint_generation = old.checkpoint_generation + 1L
  let segment_id = old.active_segment_id + 1L
  let required_features = feature_mqtt5_model |
    (if self.policy_state is Some(_) { feature_policy_gate } else { 0U }) |
    (if snapshot.groups.is_empty() { 0U } else { feature_shared_records })
  let checkpoint : WalCheckpointV5 = {
    generation: checkpoint_generation,
    lsn: self.committed_lsn,
    identities,
    required_features,
    policy: self.policy_state,
    snapshot,
  }
  let checkpoint_bytes = match encode_wal_checkpoint_v5(checkpoint) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let header_bytes = match
    encode_wal_segment_header({
      segment_id,
      first_lsn: self.committed_lsn + 1L,
      previous_lsn: self.committed_lsn,
      logical_schema: mqtt5_wal_logical_schema,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let next_v5 : WalManifestV5 = {
    generation: old.generation + 1L,
    checkpoint_generation,
    checkpoint_lsn: self.committed_lsn,
    sealed_segments: [],
    active_segment_id: segment_id,
    active_start_lsn: self.committed_lsn + 1L,
    required_features,
  }
  let manifest_bytes = match encode_wal_manifest_v5(next_v5) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dir = self.snapshot_store.data_dir()
  let checkpoint_path = dir + "/" + wal_checkpoint_name(checkpoint_generation)
  let segment_path = dir + "/" + wal_segment_name(segment_id)
  let manifest_temp = dir + "/" + wal_manifest_temp_name
  let manifest_path = dir + "/" + wal_manifest_name
  let added = checkpoint_bytes.length().to_int64() +
    header_bytes.length().to_int64() +
    manifest_bytes.length().to_int64()
  if self.disk_bytes > self.disk_max_bytes - self.disk_reserve_bytes - added {
    return Err(
      LimitExceeded(
        resource="wal-disk-bytes",
        actual=self.disk_bytes + added,
        limit=self.disk_max_bytes - self.disk_reserve_bytes,
      ),
    )
  }
  let mut manifest_renamed = false
  let mut manifest_synced = false
  try {
    if wal_exists(checkpoint_path) ||
      wal_exists(segment_path) ||
      wal_exists(manifest_temp) {
      raise InvalidConfiguration("WAL migration found orphan target")
    }
    self.fail_if(
      CheckpointBeforeCreate,
      "v5-migration-checkpoint",
      checkpoint_path,
    )
    wal_write_synced_new(checkpoint_path, checkpoint_bytes)
    sync_directory(dir)
    self.fail_if(
      CheckpointAfterFileSync,
      "v5-migration-checkpoint",
      checkpoint_path,
    )
    wal_write_synced_new(segment_path, header_bytes)
    sync_directory(dir)
    wal_write_synced_new(manifest_temp, manifest_bytes)
    @fs.rename(manifest_temp, manifest_path, replace=true) catch {
      _ =>
        raise FileSystem(operation="v5-migration-manifest", path=manifest_path)
    }
    manifest_renamed = true
    self.fail_if(
      CheckpointAfterManifestRename,
      "v5-migration-after-manifest-rename",
      manifest_path,
    )
    sync_directory(dir)
    manifest_synced = true
    let next_file = @fs.open(
      segment_path,
      mode=WriteOnly,
      create_mode=OpenExisting,
      append=true,
    ) catch {
      _ => raise DurabilityUncertain(segment_path)
    }
    self.active_file.close()
    self.active_file = next_file
    self.active_path = segment_path
    self.active_bytes = 40L
    self.manifest_v5 = Some(next_v5)
    self.manifest = {
      generation: next_v5.generation,
      checkpoint_generation: next_v5.checkpoint_generation,
      checkpoint_lsn: next_v5.checkpoint_lsn,
      sealed_segments: [],
      active_segment_id: next_v5.active_segment_id,
      active_start_lsn: next_v5.active_start_lsn,
      policy_required: (required_features & feature_policy_gate) != 0U,
    }
    self.disk_bytes = wal_disk_usage(dir)
    Ok(())
  } catch {
    error => {
      if !manifest_renamed {
        best_effort_remove(manifest_temp)
        best_effort_remove(segment_path)
        best_effort_remove(checkpoint_path)
        sync_directory(dir) catch {
          _ => ()
        }
      }
      if manifest_renamed && !manifest_synced {
        self.fenced = true
        Err(DurabilityUncertain(manifest_path))
      } else {
        Err(error)
      }
    }
  }
}
