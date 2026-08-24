///|
pub struct PersistenceRuntime {
  store : @persistence.SnapshotStore
  sink : @persistence.SnapshotSink
  writer : @persistence.SnapshotWriter
  config : @persistence.PersistenceConfig
  mut closed : Bool
}

///|
pub fn PersistenceRuntime::new(
  store : @persistence.SnapshotStore,
  config : @persistence.PersistenceConfig,
  logger? : @observability.Logger = @observability.Logger::silent(),
) -> Result[PersistenceRuntime, @persistence.PersistenceError] {
  let sink = @persistence.SnapshotSink::new()
  match
    @persistence.SnapshotWriter::new(store, sink, config.retry_ms(), logger~) {
    Ok(writer) => Ok({ store, sink, writer, config, closed: false })
    Err(error) => Err(error)
  }
}

///|
fn PersistenceRuntime::driver_config(
  self : PersistenceRuntime,
) -> SnapshotDriverConfig {
  SnapshotDriverConfig::new(
    self.sink,
    self.config.debounce_ms(),
    self.config.max_delay_ms(),
  ).unwrap()
}

///|
pub fn PersistenceRuntime::close(self : PersistenceRuntime) -> Unit {
  if !self.closed {
    self.closed = true
    self.sink.close()
    self.store.close()
  }
}

///|
pub fn PersistenceRuntime::state(self : PersistenceRuntime) -> String {
  if self.writer.is_degraded() {
    "degraded"
  } else {
    "healthy"
  }
}

///|
async fn run_with_snapshot_writer(
  persistence : PersistenceRuntime?,
  driver : RouterDriver,
  body : async () -> Unit,
) -> Unit {
  match persistence {
    None => body()
    Some(runtime) =>
      @async.with_task_group() <| group => {
        let writer_task = group.spawn(() => runtime.writer.run())
        body()
        ignore(driver.force_snapshot())
        runtime.sink.close()
        @async.protect_from_cancel(() => writer_task.wait())
      }
  }
}
