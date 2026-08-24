///|
pub(all) struct SnapshotRequest {
  revision : Int64
  snapshot : @router.BrokerSnapshotV1
}

///|
pub struct SnapshotSink {
  queue : @async.Queue[SnapshotRequest]
  mut closed : Bool
}

///|
pub fn SnapshotSink::new() -> SnapshotSink {
  { queue: @async.Queue(kind=Blocking(1)), closed: false }
}

///|
pub fn SnapshotSink::submit(
  self : SnapshotSink,
  request : SnapshotRequest,
) -> Bool {
  if self.closed {
    return false
  }
  let submitted = self.queue.try_put(request) catch { _ => false }
  if submitted {
    return true
  }
  let _ = self.queue.try_get() catch { _ => return false }
  self.queue.try_put(request) catch {
    _ => false
  }
}

///|
pub fn SnapshotSink::close(self : SnapshotSink) -> Unit {
  if !self.closed {
    self.closed = true
    self.queue.close(clear=false)
  }
}

///|
pub struct SnapshotWriter {
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
fn SnapshotWriter::take_latest(
  self : SnapshotWriter,
  initial : SnapshotRequest,
) -> SnapshotRequest {
  let mut latest = initial
  for ;; {
    let next = self.sink.queue.try_get() catch { _ => return latest }
    match next {
      Some(value) => if value.revision > latest.revision { latest = value }
      None => return latest
    }
  }
}

///|
async fn SnapshotWriter::wait_retry_latest(
  self : SnapshotWriter,
  failed : SnapshotRequest,
) -> SnapshotRequest {
  let retry_at = @async.now() + self.retry_ms.to_int64()
  let mut latest = failed
  for ;; {
    let remaining = retry_at - @async.now()
    if remaining <= 0L {
      return self.take_latest(latest)
    }
    let timeout = if remaining > 2147483647L {
      2147483647
    } else {
      remaining.to_int()
    }
    let update = @async.with_timeout_opt(timeout, () => self.sink.queue.get()) catch {
      _ => None
    }
    match update {
      Some(request) =>
        if request.revision > latest.revision {
          latest = request
        }
      None => return self.take_latest(latest)
    }
  }
}

///|
async fn SnapshotWriter::commit(
  self : SnapshotWriter,
  request : SnapshotRequest,
) -> Bool {
  self.attempts = self.attempts + 1
  match self.store.save(request.snapshot) {
    Ok(bytes) => {
      let recovered = self.degraded
      self.degraded = false
      self.committed_revision = request.revision
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
  let mut pending : SnapshotRequest? = None
  for ;; {
    let request = match pending {
      Some(value) => value
      None => self.sink.queue.get() catch { _ => return }
    }
    let latest = self.take_latest(request)
    if latest.revision <= self.committed_revision {
      pending = None
      continue
    }
    if self.commit(latest) {
      pending = None
    } else {
      pending = Some(self.wait_retry_latest(latest))
    }
  }
}
