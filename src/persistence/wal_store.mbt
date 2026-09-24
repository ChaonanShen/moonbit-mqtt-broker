///|
let wal_manifest_name : String = "broker.manifest"

///|
let wal_manifest_temp_name : String = "broker.manifest.tmp"

///|
fn wal_checkpoint_name(generation : Int64) -> String {
  "checkpoint-" + generation.to_string() + ".snap"
}

///|
fn wal_segment_name(segment_id : Int64) -> String {
  "wal-" + segment_id.to_string() + ".log"
}

///|
async fn wal_disk_usage(dir : String) -> Int64 raise PersistenceError {
  let directory = @fs.opendir(dir) catch {
    _ => raise FileSystem(operation="wal-list-data-dir", path=dir)
  }
  defer directory.close()
  let mut total = 0L
  for ;; {
    let entry = directory.next(include_hidden=true) catch {
      _ => raise FileSystem(operation="wal-list-data-dir", path=dir)
    }
    let item = match entry {
      Some(value) => value
      None => break
    }
    let path = dir + "/" + item.name
    let kind = @fs.kind(path, follow_symlink=false) catch {
      _ => raise FileSystem(operation="wal-inspect-disk-usage", path~)
    }
    if kind != Regular {
      raise FileSystem(operation="wal-nonregular-data-entry", path~)
    }
    let file = @fs.open(path, mode=ReadOnly, create_mode=OpenExisting) catch {
      _ => raise FileSystem(operation="wal-open-disk-usage", path~)
    }
    let size = file.size() catch {
      _ => {
        file.close()
        raise FileSystem(operation="wal-stat-disk-usage", path~)
      }
    }
    file.close()
    if size < 0L || size > 9223372036854775807L - total {
      raise LimitExceeded(
        resource="wal-disk-bytes",
        actual=size,
        limit=9223372036854775807L,
      )
    }
    total += size
  }
  total
}

///|
fn valid_wal_disk_limits(
  disk_max_bytes : Int64,
  disk_reserve_bytes : Int64,
) -> Bool {
  disk_reserve_bytes >= 268435456L &&
  disk_reserve_bytes <= 9223372036854775807L - 67108864L &&
  disk_max_bytes >= disk_reserve_bytes + 67108864L &&
  disk_max_bytes <= 9223372036854775807L
}

///|
pub(all) enum WalFaultPoint {
  AppendBeforeWrite
  AppendPartialTransaction
  AppendAfterTransactions
  AppendAfterCommitFrame
  AppendBeforeSync
  AppendAfterSync
  RotateBeforeCreate
  RotateBeforeManifest
  RotateAfterManifestRename
  CheckpointBeforeCreate
  CheckpointAfterFileSync
  CheckpointAfterManifestRename
  CheckpointBeforeGc
} derive(Eq, Debug)

///|
pub struct WalRecovery {
  checkpoint : WalCheckpoint
  batches : Array[WalBatch]
  committed_lsn : Int64
  recovered_tail : Bool
  policy_required : Bool
}

///|
pub fn WalRecovery::checkpoint(self : WalRecovery) -> WalCheckpoint {
  self.checkpoint
}

///|
pub fn WalRecovery::batches(self : WalRecovery) -> Array[WalBatch] {
  self.batches
}

///|
pub fn WalRecovery::committed_lsn(self : WalRecovery) -> Int64 {
  self.committed_lsn
}

///|
pub fn WalRecovery::recovered_tail(self : WalRecovery) -> Bool {
  self.recovered_tail
}

///|
pub struct WalStore {
  snapshot_store : SnapshotStore
  mut manifest : WalManifest
  mut active_file : @fs.File
  mut active_path : String
  mut active_bytes : Int64
  mut disk_bytes : Int64
  disk_max_bytes : Int64
  disk_reserve_bytes : Int64
  mut disk_dirty : Bool
  mut fault : WalFaultPoint?
  mut committed_lsn : Int64
  mut policy_state : WalPolicyState?
  mut fenced : Bool
  mut closed : Bool
}

///|
async fn wal_write_range(
  file : @fs.File,
  path : String,
  data : Bytes,
  start : Int,
  count : Int,
) -> Unit raise PersistenceError {
  if start < 0 || count < 0 || count > data.length() - start {
    raise FileSystem(operation="wal-invalid-write-range", path~)
  }
  let end = start + count
  let mut offset = start
  while offset < end {
    let written = file.write_once(data, offset~, len=end - offset) catch {
      _ => raise FileSystem(operation="wal-write", path~)
    }
    if written <= 0 || written > end - offset {
      raise FileSystem(operation="wal-short-write", path~)
    }
    offset += written
  }
}

///|
async fn wal_write_all(
  file : @fs.File,
  path : String,
  data : Bytes,
) -> Unit raise PersistenceError {
  wal_write_range(file, path, data, 0, data.length())
}

///|
async fn wal_exists(path : String) -> Bool raise PersistenceError {
  @fs.exists(path) catch {
    _ => raise FileSystem(operation="wal-inspect", path~)
  }
}

///|
async fn wal_write_synced_new(
  path : String,
  bytes : Bytes,
) -> Unit raise PersistenceError {
  let file = @fs.open(
    path,
    mode=WriteOnly,
    create_mode=CreateNew,
    permission=0o600,
  ) catch {
    _ => raise FileSystem(operation="wal-create", path~)
  }
  let mut open = true
  defer (if open { file.close() })
  wal_write_all(file, path, bytes)
  file.sync(only_data=false) catch {
    _ => raise FileSystem(operation="wal-sync", path~)
  }
  file.close()
  open = false
}

///|
async fn wal_write_synced_new_preemptible(
  path : String,
  bytes : Bytes,
  preempt : () -> Bool,
) -> Unit raise PersistenceError {
  let file = @fs.open(
    path,
    mode=WriteOnly,
    create_mode=CreateNew,
    permission=0o600,
  ) catch {
    _ => raise FileSystem(operation="wal-checkpoint-create", path~)
  }
  let mut open = true
  defer (if open { file.close() })
  let mut offset = 0
  while offset < bytes.length() {
    if preempt() {
      raise FileSystem(operation="wal-checkpoint-preempted", path~)
    }
    let count = if bytes.length() - offset > 1048576 {
      1048576
    } else {
      bytes.length() - offset
    }
    wal_write_range(file, path, bytes, offset, count)
    offset += count
  }
  if preempt() {
    raise FileSystem(operation="wal-checkpoint-preempted", path~)
  }
  file.sync(only_data=false) catch {
    _ => raise FileSystem(operation="wal-checkpoint-sync", path~)
  }
  file.close()
  open = false
}

///|
fn WalStore::fail_if(
  self : WalStore,
  point : WalFaultPoint,
  operation : String,
  path : String,
) -> Unit raise PersistenceError {
  if self.fault == Some(point) {
    raise FileSystem(operation~, path~)
  }
}

///|
pub fn WalStore::manifest(self : WalStore) -> WalManifest {
  self.manifest
}

///|
pub fn WalStore::committed_lsn(self : WalStore) -> Int64 {
  self.committed_lsn
}

///|
pub fn WalStore::policy_state(self : WalStore) -> WalPolicyState? {
  self.policy_state
}

///|
pub fn WalStore::is_fenced(self : WalStore) -> Bool {
  self.fenced
}

///|
pub fn WalStore::close(self : WalStore) -> Unit {
  if !self.closed {
    self.closed = true
    self.fault = None
    self.active_file.close()
    self.snapshot_store.close()
  }
}

///|
pub async fn WalStore::bootstrap(
  snapshot_store : SnapshotStore,
  checkpoint : WalCheckpoint,
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
      raise InvalidConfiguration("WAL bootstrap requires an unused file set")
    }
    let checkpoint_bytes = match encode_wal_checkpoint(checkpoint) {
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
        logical_schema: 3,
      }) {
      Ok(value) => value
      Err(error) => raise error
    }
    wal_write_synced_new(active_path, header)
    sync_directory(dir)
    let manifest : WalManifest = {
      generation: 1L,
      checkpoint_generation: 1L,
      checkpoint_lsn: 0L,
      sealed_segments: [],
      active_segment_id: 1L,
      active_start_lsn: 1L,
      policy_required: checkpoint.policy is Some(_),
    }
    let manifest_bytes = match encode_wal_manifest(manifest) {
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
    Ok({
      snapshot_store,
      manifest,
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
pub async fn WalStore::recover(
  snapshot_store : SnapshotStore,
  limits : SnapshotDecodeLimits,
  max_segment_bytes? : Int = 67108864,
  disk_max_bytes? : Int64 = 1073741824L,
  disk_reserve_bytes? : Int64 = 268435456L,
) -> Result[(WalStore, WalRecovery), PersistenceError] {
  let dir = snapshot_store.data_dir()
  if !valid_wal_disk_limits(disk_max_bytes, disk_reserve_bytes) {
    return Err(InvalidConfiguration("invalid WAL disk capacity"))
  }
  let manifest_path = dir + "/" + wal_manifest_name
  try {
    let encoded_manifest = bounded_read_regular(manifest_path, 32768)
    let manifest = match decode_wal_manifest(encoded_manifest) {
      Ok(value) => value
      Err(error) => raise error
    }
    let checkpoint_path = dir +
      "/" +
      wal_checkpoint_name(manifest.checkpoint_generation)
    let encoded_checkpoint = bounded_read_regular(checkpoint_path, 134217728)
    let checkpoint = match decode_wal_checkpoint(encoded_checkpoint, limits) {
      Ok(value) => value
      Err(error) => raise error
    }
    if checkpoint.generation != manifest.checkpoint_generation ||
      checkpoint.lsn != manifest.checkpoint_lsn ||
      (!manifest.policy_required && checkpoint.policy is Some(_)) {
      raise wal_corrupt("checkpoint-manifest-mismatch", 0)
    }
    let batches : Array[WalBatch] = []
    let mut previous_lsn = checkpoint.lsn
    for sealed_segment in manifest.sealed_segments {
      let path = dir + "/" + wal_segment_name(sealed_segment.segment_id)
      let bytes = bounded_read_regular(path, max_segment_bytes)
      let scan = match scan_wal_segment(bytes, false, max_segment_bytes~) {
        Ok(value) => value
        Err(error) => raise error
      }
      if scan.header.segment_id != sealed_segment.segment_id ||
        scan.header.first_lsn != sealed_segment.start_lsn ||
        scan.header.previous_lsn != previous_lsn ||
        scan.committed_lsn != sealed_segment.end_lsn {
        raise wal_corrupt("sealed-manifest-mismatch", 0)
      }
      for batch in scan.batches {
        batches.push(batch)
      }
      previous_lsn = scan.committed_lsn
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
    for batch in scan.batches {
      batches.push(batch)
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
    let recovery = {
      checkpoint,
      batches,
      committed_lsn: scan.committed_lsn,
      recovered_tail: scan.recovered_tail,
      policy_required: manifest.policy_required,
    }
    let policy_state = match
      fold_wal_policy_batches(
        checkpoint.policy,
        batches,
        manifest.policy_required,
      ) {
      Ok(value) => value
      Err(error) => {
        active_file.close()
        raise error
      }
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
          committed_lsn: scan.committed_lsn,
          policy_state,
          fenced: false,
          closed: false,
        },
        recovery,
      ),
    )
  } catch {
    error => Err(error)
  }
}

///|
async fn WalStore::rotate(self : WalStore) -> Result[Unit, PersistenceError] {
  let current = self.manifest
  if self.closed ||
    self.fenced ||
    self.committed_lsn < current.active_start_lsn ||
    current.active_segment_id == 9223372036854775807L ||
    current.generation == 9223372036854775807L ||
    current.sealed_segments.length() >= 512 {
    return Err(InvalidConfiguration("WAL cannot rotate active segment"))
  }
  let dir = self.snapshot_store.data_dir()
  let next_id = current.active_segment_id + 1L
  let next_path = dir + "/" + wal_segment_name(next_id)
  let temp_path = dir + "/" + wal_manifest_temp_name
  let manifest_path = dir + "/" + wal_manifest_name
  try {
    if self.disk_dirty {
      self.disk_bytes = wal_disk_usage(dir)
      self.disk_dirty = false
    }
    if self.disk_bytes > self.disk_max_bytes - self.disk_reserve_bytes - 32808L {
      raise LimitExceeded(
        resource="wal-disk-bytes",
        actual=self.disk_bytes + 32808L,
        limit=self.disk_max_bytes - self.disk_reserve_bytes,
      )
    }
    if wal_exists(next_path) || wal_exists(temp_path) {
      raise InvalidConfiguration("WAL rotation found an orphan file")
    }
    let next_header = match
      encode_wal_segment_header({
        segment_id: next_id,
        first_lsn: self.committed_lsn + 1L,
        previous_lsn: self.committed_lsn,
        logical_schema: 3,
      }) {
      Ok(value) => value
      Err(error) => raise error
    }
    self.fail_if(RotateBeforeCreate, "wal-rotate-create", next_path)
    wal_write_synced_new(next_path, next_header)
    sync_directory(dir)
    let sealed_segments = current.sealed_segments.copy()
    sealed_segments.push({
      segment_id: current.active_segment_id,
      start_lsn: current.active_start_lsn,
      end_lsn: self.committed_lsn,
    })
    let next_manifest : WalManifest = {
      ..current,
      generation: current.generation + 1L,
      sealed_segments,
      active_segment_id: next_id,
      active_start_lsn: self.committed_lsn + 1L,
    }
    let encoded = match encode_wal_manifest(next_manifest) {
      Ok(value) => value
      Err(error) => raise error
    }
    self.fail_if(RotateBeforeManifest, "wal-rotate-manifest", temp_path)
    wal_write_synced_new(temp_path, encoded)
    @fs.rename(temp_path, manifest_path, replace=true) catch {
      _ => raise FileSystem(operation="wal-rotate-manifest", path=manifest_path)
    }
    self.fail_if(
      RotateAfterManifestRename,
      "wal-rotate-after-manifest-rename",
      manifest_path,
    )
    sync_directory(dir)
    let next_file = @fs.open(
      next_path,
      mode=WriteOnly,
      create_mode=OpenExisting,
      append=true,
    ) catch {
      _ => raise FileSystem(operation="wal-open-next", path=next_path)
    }
    self.active_file.close()
    self.active_file = next_file
    self.active_path = next_path
    self.active_bytes = 40L
    self.manifest = next_manifest
    self.disk_bytes = wal_disk_usage(dir)
    Ok(())
  } catch {
    error => {
      self.disk_dirty = true
      self.fenced = true
      Err(error)
    }
  }
}

///|
/// Persist the required policy capability before any policy transaction can
/// be committed. A crash after this manifest switch but before activation is
/// recoverable by the new reader; an old reader rejects manifest version 2.
pub async fn WalStore::require_policy_capability(
  self : WalStore,
) -> Result[Unit, PersistenceError] {
  if self.manifest.policy_required {
    return Ok(())
  }
  if self.closed ||
    self.fenced ||
    self.manifest.generation == 9223372036854775807L {
    return Err(InvalidConfiguration("WAL policy capability unavailable"))
  }
  let dir = self.snapshot_store.data_dir()
  let temp = dir + "/" + wal_manifest_temp_name
  let path = dir + "/" + wal_manifest_name
  try {
    if wal_exists(temp) {
      raise InvalidConfiguration("WAL policy upgrade found orphan manifest")
    }
    let next : WalManifest = {
      ..self.manifest,
      generation: self.manifest.generation + 1L,
      policy_required: true,
    }
    let encoded = match encode_wal_manifest(next) {
      Ok(value) => value
      Err(error) => raise error
    }
    if self.disk_dirty {
      self.disk_bytes = wal_disk_usage(dir)
      self.disk_dirty = false
    }
    if self.disk_bytes >
      self.disk_max_bytes -
      self.disk_reserve_bytes -
      encoded.length().to_int64() {
      raise LimitExceeded(
        resource="wal-disk-bytes",
        actual=self.disk_bytes + encoded.length().to_int64(),
        limit=self.disk_max_bytes - self.disk_reserve_bytes,
      )
    }
    wal_write_synced_new(temp, encoded)
    @fs.rename(temp, path, replace=true) catch {
      _ => raise FileSystem(operation="wal-policy-manifest-rename", path~)
    }
    sync_directory(dir)
    self.manifest = next
    self.disk_bytes = wal_disk_usage(dir)
    Ok(())
  } catch {
    error => {
      self.disk_dirty = true
      self.fenced = true
      Err(error)
    }
  }
}

///|
pub async fn WalStore::append_batch(
  self : WalStore,
  batch : WalBatch,
  max_segment_bytes? : Int = 67108864,
) -> Result[Int64, PersistenceError] {
  if self.closed || self.fenced || batch.previous_lsn != self.committed_lsn {
    return Err(FileSystem(operation="wal-not-writable", path=self.active_path))
  }
  if batch.transactions.length() != 1 &&
    batch.transactions.any(item => is_wal_policy_record(item.delta)) {
    return Err(InvalidConfiguration("policy WAL transition must be standalone"))
  }
  let next_policy = match
    fold_wal_policy_batches(
      self.policy_state,
      [batch],
      self.manifest.policy_required,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let encoded = match encode_wal_batch(batch) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if max_segment_bytes < 40 ||
    encoded.length().to_int64() > max_segment_bytes.to_int64() - 40L {
    return Err(
      LimitExceeded(
        resource="wal-segment-bytes",
        actual=40L + encoded.length().to_int64(),
        limit=max_segment_bytes.to_int64(),
      ),
    )
  }
  if self.disk_dirty {
    self.disk_bytes = wal_disk_usage(self.snapshot_store.data_dir()) catch {
      _ => {
        self.fenced = true
        return Err(
          FileSystem(operation="wal-disk-usage", path=self.active_path),
        )
      }
    }
    self.disk_dirty = false
  }
  if self.disk_bytes >
    self.disk_max_bytes - self.disk_reserve_bytes - encoded.length().to_int64() {
    return Err(
      LimitExceeded(
        resource="wal-disk-bytes",
        actual=self.disk_bytes + encoded.length().to_int64(),
        limit=self.disk_max_bytes - self.disk_reserve_bytes,
      ),
    )
  }
  if self.active_bytes >
    max_segment_bytes.to_int64() - encoded.length().to_int64() {
    match self.rotate() {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  try {
    self.fail_if(AppendBeforeWrite, "wal-append-before-write", self.active_path)
    let commit_offset = encoded.length() - 41
    if commit_offset < 0 {
      raise FileSystem(
        operation="wal-invalid-batch-frame",
        path=self.active_path,
      )
    }
    if self.fault == Some(AppendPartialTransaction) {
      wal_write_range(
        self.active_file,
        self.active_path,
        encoded,
        0,
        if commit_offset > 1 {
          commit_offset / 2
        } else {
          1
        },
      )
      raise FileSystem(
        operation="wal-partial-transaction",
        path=self.active_path,
      )
    }
    wal_write_range(
      self.active_file,
      self.active_path,
      encoded,
      0,
      commit_offset,
    )
    self.fail_if(
      AppendAfterTransactions,
      "wal-after-transactions",
      self.active_path,
    )
    wal_write_range(
      self.active_file,
      self.active_path,
      encoded,
      commit_offset,
      41,
    )
    self.fail_if(AppendAfterCommitFrame, "wal-after-commit", self.active_path)
    self.fail_if(AppendBeforeSync, "wal-before-sync", self.active_path)
    self.active_file.sync(only_data=false) catch {
      _ => raise FileSystem(operation="wal-sync-active", path=self.active_path)
    }
    self.fail_if(AppendAfterSync, "wal-after-sync", self.active_path)
    self.active_bytes += encoded.length().to_int64()
    self.disk_bytes += encoded.length().to_int64()
    self.committed_lsn = batch.transactions[batch.transactions.length() - 1].lsn
    self.policy_state = next_policy
    Ok(self.committed_lsn)
  } catch {
    error => {
      self.fenced = true
      Err(error)
    }
  }
}

///|
/// Publish a checkpoint only after the driver has applied the selected LSN.
/// The active segment is rotated first, so every segment removed after
/// manifest publication ends at or before the checkpoint LSN.
pub async fn WalStore::publish_checkpoint(
  self : WalStore,
  checkpoint : WalCheckpoint,
  preempt? : () -> Bool = () => false,
) -> Result[Unit, PersistenceError] {
  if self.closed ||
    self.fenced ||
    checkpoint.lsn != self.committed_lsn ||
    self.manifest.checkpoint_generation == 9223372036854775807L ||
    self.manifest.generation == 9223372036854775807L ||
    checkpoint.generation != self.manifest.checkpoint_generation + 1L ||
    (!self.manifest.policy_required && checkpoint.policy is Some(_)) ||
    checkpoint.policy != self.policy_state {
    return Err(InvalidConfiguration("invalid WAL checkpoint publication"))
  }
  let encoded = match encode_wal_checkpoint_sliced(checkpoint, preempt~) {
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
  let old = self.manifest
  let mut manifest_renamed = false
  let mut manifest_synced = false
  let mut checkpoint_creation_attempted = false
  try {
    if wal_exists(final_path) ||
      wal_exists(temp_path) ||
      wal_exists(manifest_temp) {
      raise InvalidConfiguration("checkpoint publication found an orphan file")
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
    let next_manifest : WalManifest = {
      ..old,
      generation: old.generation + 1L,
      checkpoint_generation: checkpoint.generation,
      checkpoint_lsn: checkpoint.lsn,
      sealed_segments: [],
    }
    let manifest_bytes = match encode_wal_manifest(next_manifest) {
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
    self.manifest = next_manifest
    self.fail_if(CheckpointBeforeGc, "wal-checkpoint-before-gc", manifest_path)
    // GC is safe only after the new manifest's directory entry is synced.
    let old_checkpoint = dir +
      "/" +
      wal_checkpoint_name(old.checkpoint_generation)
    @fs.remove(old_checkpoint) catch {
      _ => ()
    }
    for segment in old.sealed_segments {
      let old_segment = dir + "/" + wal_segment_name(segment.segment_id)
      @fs.remove(old_segment) catch {
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
