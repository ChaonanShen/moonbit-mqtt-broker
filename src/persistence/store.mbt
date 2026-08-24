///|
let snapshot_main_name : String = "broker.snapshot"

///|
let snapshot_temp_name : String = "broker.snapshot.tmp"

///|
let snapshot_lock_name : String = "broker.snapshot.lock"

///|
pub(all) enum StoreFaultPoint {
  TempOpen
  TempWrite
  TempSync
  TempClose
  Rename
  DirectorySync
} derive(Eq, Debug)

///|
pub struct SnapshotStore {
  config : PersistenceConfig
  data_dir : String
  main_path : String
  temp_path : String
  lock_path : String
  lock_file : @fs.File
  mut closed : Bool
  mut fault : StoreFaultPoint?
}

///|
async fn mkdir_data_dir(path : String) -> Unit raise PersistenceError {
  let exists = @fs.exists(path) catch {
    _ => raise FileSystem(operation="inspect-data-dir", path~)
  }
  if !exists {
    @fs.mkdir(path, permission=0o700, recursive=true) catch {
      _ => raise FileSystem(operation="mkdir-data-dir", path~)
    }
  }
}

///|
async fn canonical_data_dir(path : String) -> String raise PersistenceError {
  @fs.realpath(path) catch {
    _ => raise FileSystem(operation="realpath-data-dir", path~)
  }
}

///|
async fn open_lock_file(path : String) -> @fs.File raise PersistenceError {
  let exists = @fs.exists(path) catch {
    _ => raise FileSystem(operation="inspect-lock", path~)
  }
  if exists {
    let kind = @fs.kind(path, follow_symlink=false) catch {
      _ => raise FileSystem(operation="inspect-lock", path~)
    }
    if kind != Regular {
      raise FileSystem(operation="lock-not-regular", path~)
    }
  }
  @fs.open(path, mode=ReadWrite, create_mode=OpenOrCreate, permission=0o600) catch {
    _ => raise FileSystem(operation="open-lock", path~)
  }
}

///|
async fn best_effort_remove(path : String) -> Unit {
  if @fs.exists(path) {
    @fs.remove(path) catch {
      _ => ()
    }
  }
}

///|
pub async fn SnapshotStore::open(
  config : PersistenceConfig,
) -> Result[SnapshotStore, PersistenceError] {
  try {
    mkdir_data_dir(config.data_dir())
    let data_dir = canonical_data_dir(config.data_dir())
    let kind = @fs.kind(data_dir, follow_symlink=false) catch {
      _ => raise FileSystem(operation="inspect-data-dir", path=data_dir)
    }
    if kind != Directory {
      raise FileSystem(operation="data-dir-not-directory", path=data_dir)
    }
    @fs.chmod(data_dir, 0o700) catch {
      _ => raise FileSystem(operation="chmod-data-dir", path=data_dir)
    }
    let main_path = data_dir + "/" + snapshot_main_name
    let temp_path = data_dir + "/" + snapshot_temp_name
    let lock_path = data_dir + "/" + snapshot_lock_name
    let lock_file = open_lock_file(lock_path)
    let acquired = lock_file.try_lock(Exclusive) catch {
      _ => {
        lock_file.close()
        raise FileSystem(operation="lock-data-dir", path=lock_path)
      }
    }
    if !acquired {
      lock_file.close()
      return Err(LockConflict(lock_path))
    }
    // A temp file is never a recovery source. Removal is intentionally best-effort.
    best_effort_remove(temp_path)
    Ok({
      config,
      data_dir,
      main_path,
      temp_path,
      lock_path,
      lock_file,
      closed: false,
      fault: None,
    })
  } catch {
    _ => Err(FileSystem(operation="open-store", path=config.data_dir()))
  }
}

///|
pub fn SnapshotStore::data_dir(self : SnapshotStore) -> String {
  self.data_dir
}

///|
pub fn SnapshotStore::main_path(self : SnapshotStore) -> String {
  self.main_path
}

///|
pub fn SnapshotStore::temp_path(self : SnapshotStore) -> String {
  self.temp_path
}

///|
pub fn SnapshotStore::lock_path(self : SnapshotStore) -> String {
  self.lock_path
}

///|
fn SnapshotStore::fail_if(
  self : SnapshotStore,
  point : StoreFaultPoint,
  operation : String,
  path : String,
) -> Unit raise PersistenceError {
  if self.fault == Some(point) {
    raise FileSystem(operation~, path~)
  }
}

///|
pub fn SnapshotStore::close(self : SnapshotStore) -> Unit {
  if !self.closed {
    self.closed = true
    self.fault = None
    self.lock_file.unlock()
    self.lock_file.close()
  }
}

///|
async fn bounded_read_regular(
  path : String,
  max_bytes : Int,
) -> Bytes raise PersistenceError {
  let kind = @fs.kind(path, follow_symlink=false) catch {
    _ => raise FileSystem(operation="inspect-snapshot", path~)
  }
  if kind != Regular {
    raise FileSystem(operation="snapshot-not-regular", path~)
  }
  let file = @fs.open(path, mode=ReadOnly, create_mode=OpenExisting) catch {
    _ => raise FileSystem(operation="open-snapshot", path~)
  }
  let size = file.size() catch {
    _ => {
      file.close()
      raise FileSystem(operation="stat-snapshot", path~)
    }
  }
  if size > max_bytes.to_int64() {
    file.close()
    raise SnapshotTooLarge(actual=size, limit=max_bytes.to_int64())
  }
  let capacity = size.to_int() + 1
  let buffer = FixedArray::make(capacity, b'\x00')
  let mut total = 0
  while total < capacity {
    let count = file.read_at(
      buffer,
      position=total.to_int64(),
      offset=total,
      len=capacity - total,
    ) catch {
      _ => {
        file.close()
        raise FileSystem(operation="read-snapshot", path~)
      }
    }
    if count == 0 {
      break
    }
    total = total + count
  }
  file.close()
  if total > max_bytes {
    raise SnapshotTooLarge(actual=total.to_int64(), limit=max_bytes.to_int64())
  }
  buffer.unsafe_reinterpret_as_bytes()[:total].to_owned()
}

///|
pub async fn SnapshotStore::load_state(
  self : SnapshotStore,
  broker_config : @router.BrokerConfig,
  max_message_payload_bytes : Int,
) -> Result[@router.BrokerState, PersistenceError] {
  if !@fs.exists(self.main_path) {
    return Ok(@router.BrokerState::new(broker_config))
  }
  try {
    let max_bytes = self.config.max_snapshot_bytes().to_int()
    let data = bounded_read_regular(self.main_path, max_bytes)
    let limits = match
      SnapshotDecodeLimits::new(
        broker_config,
        max_message_payload_bytes,
        max_snapshot_bytes=max_bytes,
      ) {
      Ok(value) => value
      Err(error) => raise error
    }
    let snapshot = match decode_snapshot(data, limits) {
      Ok(value) => value
      Err(error) => raise error
    }
    match @router.BrokerState::from_snapshot(broker_config, snapshot) {
      Ok(state) => Ok(state)
      Err(_) => Err(SnapshotImport("router rejected decoded snapshot"))
    }
  } catch {
    error => Err(error)
  }
}

///|
async fn sync_directory(path : String) -> Unit raise PersistenceError {
  let directory = @fs.open(path, mode=ReadOnly, create_mode=OpenExisting) catch {
    _ => raise FileSystem(operation="open-data-dir-for-sync", path~)
  }
  directory.sync(only_data=false) catch {
    _ => {
      directory.close()
      raise FileSystem(operation="sync-data-dir", path~)
    }
  }
  directory.close()
}

///|
pub async fn SnapshotStore::save(
  self : SnapshotStore,
  snapshot : @router.BrokerSnapshotV1,
) -> Result[Int, PersistenceError] {
  if self.closed {
    return Err(FileSystem(operation="save-closed-store", path=self.data_dir))
  }
  let max_bytes = self.config.max_snapshot_bytes().to_int()
  let encoded = match encode_snapshot(snapshot, max_snapshot_bytes=max_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut renamed = false
  try {
    best_effort_remove(self.temp_path)
    self.fail_if(TempOpen, "create-temp", self.temp_path)
    let temp = @fs.open(
      self.temp_path,
      mode=WriteOnly,
      create_mode=CreateNew,
      permission=0o600,
    ) catch {
      _ => raise FileSystem(operation="create-temp", path=self.temp_path)
    }
    let mut temp_open = true
    defer (if temp_open { temp.close() })
    self.fail_if(TempWrite, "write-temp", self.temp_path)
    temp.write(encoded) catch {
      _ => raise FileSystem(operation="write-temp", path=self.temp_path)
    }
    self.fail_if(TempSync, "sync-temp", self.temp_path)
    temp.sync(only_data=false) catch {
      _ => raise FileSystem(operation="sync-temp", path=self.temp_path)
    }
    self.fail_if(TempClose, "close-temp", self.temp_path)
    temp.close()
    temp_open = false
    self.fail_if(Rename, "rename-temp", self.temp_path)
    @fs.rename(self.temp_path, self.main_path, replace=true) catch {
      _ => raise FileSystem(operation="rename-temp", path=self.temp_path)
    }
    renamed = true
    self.fail_if(DirectorySync, "sync-data-dir", self.data_dir)
    sync_directory(self.data_dir)
    Ok(encoded.length())
  } catch {
    _ =>
      if !renamed {
        best_effort_remove(self.temp_path)
        Err(FileSystem(operation="snapshot-save", path=self.temp_path))
      } else {
        Err(DurabilityUncertain(self.main_path))
      }
  }
}
