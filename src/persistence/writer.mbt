///|
pub(all) struct SnapshotRequest {
  revision : Int64
  snapshot : @router.BrokerSnapshotV3
}

///|
priv struct SnapshotEnvelope {
  revision : Int64
  snapshot : @router.BrokerSnapshotV3
  ticket : @budget.Ticket?
}

///|
fn SnapshotEnvelope::release(self : SnapshotEnvelope) -> Unit {
  if self.ticket is Some(ticket) {
    ticket.release().unwrap()
  }
}

///|
pub struct SnapshotSink {
  priv queue : @async.Queue[SnapshotEnvelope]
  mut committed : Int64
  mut closed : Bool
}

///|
pub fn SnapshotSink::new() -> SnapshotSink {
  { queue: @async.Queue(kind=Blocking(1)), closed: false, committed: -1L }
}

///|
fn SnapshotSink::submit_envelope(
  self : SnapshotSink,
  request : SnapshotEnvelope,
) -> Bool {
  if self.closed {
    return false
  }
  if (self.queue.try_put(request) catch { _ => false }) {
    return true
  }
  let previous = self.queue.try_get() catch { _ => return false }
  if previous is Some(previous) {
    previous.release()
  }
  self.queue.try_put(request) catch {
    _ => false
  }
}

///|
pub fn SnapshotSink::submit(
  self : SnapshotSink,
  request : SnapshotRequest,
) -> Bool {
  self.submit_envelope({
    revision: request.revision,
    snapshot: request.snapshot,
    ticket: None,
  })
}

///|
/// Ownership transfers iff true. The caller releases a rejected ticket.
pub fn SnapshotSink::submit_accounted(
  self : SnapshotSink,
  request : SnapshotRequest,
  ticket : @budget.Ticket,
) -> Bool {
  self.submit_envelope({
    revision: request.revision,
    snapshot: request.snapshot,
    ticket: Some(ticket),
  })
}

///|
pub fn SnapshotSink::close(self : SnapshotSink) -> Unit {
  if !self.closed {
    self.closed = true
    self.queue.close(clear=false)
  }
}

///|
pub fn SnapshotSink::discard(self : SnapshotSink) -> Unit {
  for ;; {
    let next = self.queue.try_get() catch { _ => None }
    match next {
      Some(value) => value.release()
      None => break
    }
  }
  self.closed = true
  self.queue.close(clear=true)
}

///|
pub struct SnapshotWriter {
  priv mut active : SnapshotEnvelope?
  store : SnapshotStore
  sink : SnapshotSink
  retry_ms : Int
  mut committed_revision : Int64
  mut degraded : Bool
  mut attempts : Int
  logger : @observability.Logger
}

///|
pub fn SnapshotWriter::new(
  store : SnapshotStore,
  sink : SnapshotSink,
  retry_ms : Int64,
  logger? : @observability.Logger = @observability.Logger::silent(),
) -> Result[SnapshotWriter, PersistenceError] {
  if retry_ms < 1L || retry_ms > 2147483647L {
    return Err(
      InvalidConfiguration("retry_ms must be between 1 and 2147483647"),
    )
  }
  Ok({
    active: None,
    store,
    sink,
    retry_ms: retry_ms.to_int(),
    committed_revision: -1L,
    degraded: false,
    attempts: 0,
    logger,
  })
}

///|
pub fn SnapshotWriter::committed_revision(self : SnapshotWriter) -> Int64 {
  self.committed_revision
}

///|
pub fn SnapshotWriter::is_degraded(self : SnapshotWriter) -> Bool {
  self.degraded
}

///|
pub fn SnapshotWriter::attempt_count(self : SnapshotWriter) -> Int {
  self.attempts
}

///|
fn SnapshotWriter::install_latest(
  self : SnapshotWriter,
  request : SnapshotEnvelope,
) -> Unit {
  match self.active {
    None => self.active = Some(request)
    Some(previous) =>
      if request.revision > previous.revision {
        previous.release()
        self.active = Some(request)
      } else {
        request.release()
      }
  }
}

///|
fn SnapshotWriter::release_active(self : SnapshotWriter) -> Unit {
  if self.active is Some(active) {
    active.release()
    self.active = None
  }
}

///|
fn SnapshotWriter::take_latest(self : SnapshotWriter) -> Unit {
  for ;; {
    let next = self.sink.queue.try_get() catch { _ => None }
    match next {
      Some(value) => self.install_latest(value)
      None => return
    }
  }
}

///|
async fn SnapshotWriter::wait_retry_latest(self : SnapshotWriter) -> Unit {
  let deadline = @async.now() + self.retry_ms.to_int64()
  for ;; {
    let remaining = deadline - @async.now()
    if remaining <= 0L {
      self.take_latest()
      return
    }
    let timeout = if remaining > 2147483647L {
      2147483647
    } else {
      remaining.to_int()
    }
    let next = @async.with_timeout_opt(timeout, () => self.sink.queue.get()) catch {
      _ => None
    }
    match next {
      Some(value) => self.install_latest(value)
      None => {
        self.take_latest()
        return
      }
    }
  }
}

///|
async fn SnapshotWriter::commit(
  self : SnapshotWriter,
  request : SnapshotEnvelope,
) -> Bool {
  self.attempts = self.attempts + 1
  match @async.protect_from_cancel(() => self.store.save(request.snapshot)) {
    Ok(bytes) => {
      let recovered = self.degraded
      self.degraded = false
      self.committed_revision = request.revision
      self.sink.committed = request.revision
      if recovered {
        self.logger.log(
          @observability.LogRecord::new(
            @async.now(),
            @observability.Info,
            "persistence_recovered",
            message="snapshot persistence recovered revision=" +
              request.revision.to_string(),
            snapshot_revision=request.revision.to_string(),
          ),
        )
      }
      self.logger.log(
        @observability.LogRecord::new(
          @async.now(),
          @observability.Info,
          "snapshot_committed",
          message="snapshot committed revision=" +
            request.revision.to_string() +
            " bytes=" +
            bytes.to_string(),
          snapshot_revision=request.revision.to_string(),
        ),
      )
      true
    }
    Err(error) => {
      self.degraded = true
      self.logger.log(
        @observability.LogRecord::new(
          @async.now(),
          @observability.Error,
          "snapshot_failed",
          message="snapshot failed revision=" +
            request.revision.to_string() +
            " category=" +
            error.category() +
            " persistence=degraded",
          reason=error.category(),
          snapshot_revision=request.revision.to_string(),
        ),
      )
      false
    }
  }
}

///|
pub async fn SnapshotWriter::run(self : SnapshotWriter) -> Unit {
  defer {
    self.release_active()
    self.sink.discard()
  }
  for ;; {
    if self.active is None {
      let request = self.sink.queue.get() catch { _ => return }
      self.active = Some(request)
    }
    self.take_latest()
    let request = self.active.unwrap()
    if request.revision <= self.committed_revision {
      self.release_active()
      continue
    }
    if self.commit(request) {
      self.release_active()
    } else {
      if self.sink.closed {
        return
      }
      self.wait_retry_latest()
    }
  }
}

///|
pub fn SnapshotSink::committed_revision(self : SnapshotSink) -> Int64 {
  self.committed
}
