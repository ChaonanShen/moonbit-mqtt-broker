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
pub struct WalRecovery {
  checkpoint : WalCheckpoint
  batches : Array[WalBatch]
  committed_lsn : Int64
  recovered_tail : Bool
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
  mut committed_lsn : Int64
  mut fenced : Bool
  mut closed : Bool
}

///|
async fn wal_write_all(
  file : @fs.File,
  path : String,
  data : Bytes,
) -> Unit raise PersistenceError {
  let mut offset = 0
  while offset < data.length() {
    let count = file.write_once(data, offset~, len=data.length() - offset) catch {
      _ => raise FileSystem(operation="wal-write", path~)
    }
    if count <= 0 || count > data.length() - offset {
      raise FileSystem(operation="wal-short-write", path~)
    }
    offset += count
  }
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
pub fn WalStore::manifest(self : WalStore) -> WalManifest {
  self.manifest
}

///|
pub fn WalStore::committed_lsn(self : WalStore) -> Int64 {
  self.committed_lsn
}

///|
pub fn WalStore::is_fenced(self : WalStore) -> Bool {
  self.fenced
}

///|
pub fn WalStore::close(self : WalStore) -> Unit {
  if !self.closed {
    self.closed = true
    self.active_file.close()
    self.snapshot_store.close()
  }
}

///|
pub async fn WalStore::bootstrap(
  snapshot_store : SnapshotStore,
  checkpoint : WalCheckpoint,
) -> Result[WalStore, PersistenceError] {
  let dir = snapshot_store.data_dir()
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
    Ok({
      snapshot_store,
      manifest,
      active_file,
      active_path,
      active_bytes: 40L,
      committed_lsn: 0L,
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
) -> Result[(WalStore, WalRecovery), PersistenceError] {
  let dir = snapshot_store.data_dir()
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
      checkpoint.lsn != manifest.checkpoint_lsn {
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
    let recovery = {
      checkpoint,
      batches,
      committed_lsn: scan.committed_lsn,
      recovered_tail: scan.recovered_tail,
    }
    Ok(
      (
        {
          snapshot_store,
          manifest,
          active_file,
          active_path,
          active_bytes: scan.committed_bytes.to_int64(),
          committed_lsn: scan.committed_lsn,
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
    wal_write_synced_new(temp_path, encoded)
    @fs.rename(temp_path, manifest_path, replace=true) catch {
      _ => raise FileSystem(operation="wal-rotate-manifest", path=manifest_path)
    }
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
    Ok(())
  } catch {
    error => {
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
  if self.active_bytes >
    max_segment_bytes.to_int64() - encoded.length().to_int64() {
    match self.rotate() {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  try {
    wal_write_all(self.active_file, self.active_path, encoded)
    self.active_file.sync(only_data=false) catch {
      _ => raise FileSystem(operation="wal-sync-active", path=self.active_path)
    }
    self.active_bytes += encoded.length().to_int64()
    self.committed_lsn = batch.transactions[batch.transactions.length() - 1].lsn
    Ok(self.committed_lsn)
  } catch {
    error => {
      self.fenced = true
      Err(error)
    }
  }
}
