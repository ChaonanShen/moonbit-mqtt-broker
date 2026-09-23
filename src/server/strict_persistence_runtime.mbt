///|
pub struct StrictPersistenceRuntime {
  writer : @persistence.WalWriter
  coordinator : CommitCoordinator
  generations : Map[@session.ClientId, Int64]
  mut closed : Bool
}

///|
pub fn StrictPersistenceRuntime::new(
  store : @persistence.WalStore,
  initial_state : @router.BrokerState,
  identities : Array[@persistence.WalSessionIdentity],
  committed_lsn : Int64,
) -> Result[StrictPersistenceRuntime, @persistence.PersistenceError] {
  let generations : Map[@session.ClientId, Int64] = Map([])
  for identity in identities {
    let client_id = match @session.ClientId::new(identity.client_id) {
      Ok(value) => value
      Err(_) => return Err(@persistence.SnapshotImport("invalid WAL client id"))
    }
    if identity.generation < 1L ||
      generations.contains(client_id) ||
      !initial_state.has_session(client_id) {
      return Err(@persistence.SnapshotImport("invalid WAL session identity"))
    }
    generations.set(client_id, identity.generation)
  }
  if generations.length() != initial_state.export_snapshot().sessions.length() {
    return Err(@persistence.SnapshotImport("WAL identity count mismatch"))
  }
  let writer = @persistence.WalWriter::new(store)
  let limits = initial_state.config().resources()
  let coordinator = match
    CommitCoordinator::new(
      writer,
      initial_state.resource_ledger(),
      limits.get("max_wal_pending_bytes_total"),
      1048576,
      1L,
      committed_lsn,
      broker=initial_state,
    ) {
    Ok(value) => value
    Err(_) =>
      return Err(
        @persistence.InvalidConfiguration("strict coordinator unavailable"),
      )
  }
  Ok({ writer, coordinator, generations, closed: false })
}

///|
pub fn StrictPersistenceRuntime::coordinator(
  self : StrictPersistenceRuntime,
) -> CommitCoordinator {
  self.coordinator
}

///|
pub fn StrictPersistenceRuntime::generations(
  self : StrictPersistenceRuntime,
) -> Map[@session.ClientId, Int64] {
  self.generations
}

///|
pub fn StrictPersistenceRuntime::state(
  self : StrictPersistenceRuntime,
) -> String {
  if self.coordinator.is_fenced() {
    "fenced"
  } else {
    "healthy"
  }
}

///|
pub fn StrictPersistenceRuntime::close(self : StrictPersistenceRuntime) -> Unit {
  if !self.closed {
    self.writer.close_requests()
    self.writer.close_store()
    self.closed = true
  }
}

///|
async fn run_with_strict_writer(
  strict : StrictPersistenceRuntime?,
  driver : RouterDriver,
  bus : EventBus,
  body : async () -> Unit,
) -> Unit {
  match strict {
    None => body()
    Some(runtime) =>
      @async.with_task_group() <| group => {
        let writer_task = group.spawn(() => {
          runtime.writer.run(() => bus.post_wal_completion())
        })
        errdefer @async.protect_from_cancel(() => {
          runtime.writer.close_requests()
          writer_task.wait()
          runtime.writer.close_store()
          runtime.closed = true
        })
        body()
        driver.shutdown_authentication()
        driver.shutdown_strict()
        runtime.writer.close_requests()
        @async.protect_from_cancel(() => writer_task.wait())
        driver.handle(WalCompletionDue)
        runtime.writer.close_store()
        runtime.closed = true
        if runtime.coordinator.has_pending() || runtime.coordinator.is_fenced() {
          raise @persistence.DurabilityUncertain("strict WAL did not drain")
        }
      }
  }
}

///|
async fn run_with_persistence_writers(
  snapshot : PersistenceRuntime?,
  strict : StrictPersistenceRuntime?,
  driver : RouterDriver,
  bus : EventBus,
  body : async () -> Unit,
) -> Unit {
  run_with_strict_writer(strict, driver, bus, () => {
    run_with_snapshot_writer(snapshot, driver, body)
  })
}
