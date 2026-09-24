///|
pub(all) enum CacheError {
  Closed
  Unavailable
  Stale
  ResponseTooLarge
} derive(Eq, Debug)

///|
pub struct CachedObservation {
  sample : ObservationSnapshot
  metrics_body : Bytes?
}

///|
/// The parent ledger ticket covers a current and a building workspace.
/// Handlers receive their own encoded Bytes and never borrow a replaceable
/// cache entry across await.
pub struct ObservationCache {
  config : ManagementConfig
  mut snapshot_max_age_ms : Int
  owner : ManagementBudget
  mut current : CachedObservation?
  mut latest_driver_progress_ms : Int64
  mut stopping : Bool
  mut closed : Bool
}

///|
pub fn ObservationCache::new(
  owner : ManagementBudget,
) -> Result[ObservationCache, CacheError] {
  if !owner.register_cache() {
    return Err(Closed)
  }
  Ok({
    config: owner.config(),
    snapshot_max_age_ms: owner.config().snapshot_max_age_ms(),
    owner,
    current: None,
    latest_driver_progress_ms: -1L,
    stopping: false,
    closed: false,
  })
}

///|
/// Updated at the non-awaiting generation publication boundary.
pub fn ObservationCache::update_reload_max_age(
  self : ObservationCache,
  interval_ms : Int,
  max_age_ms : Int,
) -> Bool {
  if self.closed ||
    interval_ms < 100 ||
    interval_ms > 10000 ||
    max_age_ms < 300 ||
    max_age_ms > 60000 ||
    max_age_ms < 3 * interval_ms {
    return false
  }
  self.snapshot_max_age_ms = max_age_ms
  true
}

///|
/// A failed publication leaves the previous snapshot and timestamp intact.
pub fn ObservationCache::publish(
  self : ObservationCache,
  sample : ObservationSnapshot,
  metrics_body? : Bytes,
) -> Bool {
  if self.closed ||
    self.stopping ||
    sample.captured_monotonic_ms < 0L ||
    sample.driver_progress_monotonic_ms < 0L ||
    sample.driver_progress_monotonic_ms > sample.captured_monotonic_ms {
    return false
  }
  if self.current is Some(previous) &&
    (
      sample.boot_id != previous.sample.boot_id ||
      sample.captured_monotonic_ms < previous.sample.captured_monotonic_ms
    ) {
    return false
  }
  if metrics_body is Some(body) &&
    body.length() > self.config.max_response_bytes() {
    return false
  }
  let status = encode_status(
    sample,
    sample.captured_monotonic_ms,
    self.snapshot_max_age_ms.to_int64(),
    self.snapshot_max_age_ms.to_int64(),
  )
  if status.length() > self.config.max_response_bytes() {
    return false
  }
  if sample.driver_progress_monotonic_ms > self.latest_driver_progress_ms {
    self.latest_driver_progress_ms = sample.driver_progress_monotonic_ms
  }
  self.current = Some({ sample, metrics_body })
  true
}

///|
/// Driver calls this only after a real event has finished. The ticker must
/// never update it merely because it queued an observation notification.
pub fn ObservationCache::update_driver_progress(
  self : ObservationCache,
  completed_monotonic_ms : Int64,
) -> Unit {
  if !self.closed &&
    completed_monotonic_ms >= 0L &&
    completed_monotonic_ms > self.latest_driver_progress_ms {
    self.latest_driver_progress_ms = completed_monotonic_ms
  }
}

///|
pub fn ObservationCache::captured_at(self : ObservationCache) -> Int64? {
  self.current.map(entry => entry.sample.captured_monotonic_ms)
}

///|
pub fn ObservationCache::health(
  self : ObservationCache,
  now_monotonic_ms : Int64,
) -> Result[HealthDecision, CacheError] {
  if self.closed {
    return Err(Closed)
  }
  let entry = match self.current {
    Some(value) => value
    None => return Err(Unavailable)
  }
  let decision = evaluate_health(
    entry.sample,
    now_monotonic_ms,
    self.snapshot_max_age_ms.to_int64(),
    self.snapshot_max_age_ms.to_int64(),
    driver_progress_override=self.latest_driver_progress_ms,
  )
  if self.stopping {
    let reasons = decision.reasons.copy()
    if !reasons.contains("stopping") {
      reasons.push("stopping")
    }
    Ok({ ..decision, ready: false, reasons })
  } else {
    Ok(decision)
  }
}

///|
fn ObservationCache::readable(
  self : ObservationCache,
  now_monotonic_ms : Int64,
) -> Result[CachedObservation, CacheError] {
  if self.closed {
    return Err(Closed)
  }
  if self.stopping {
    return Err(Stale)
  }
  let entry = match self.current {
    Some(value) => value
    None => return Err(Unavailable)
  }
  let health = self.health(now_monotonic_ms).unwrap()
  if health.reasons.contains("clock_unavailable") ||
    health.reasons.contains("driver_stale") ||
    health.reasons.contains("observation_stale") ||
    entry.sample.lifecycle == Stopping ||
    entry.sample.lifecycle == Failed {
    return Err(Stale)
  }
  Ok(entry)
}

///|
pub fn ObservationCache::status_body(
  self : ObservationCache,
  now_monotonic_ms : Int64,
  details_enabled? : Bool = false,
  operations_enabled? : Bool = false,
  details_available? : Bool = false,
  reload_enabled? : Bool = false,
) -> Result[Bytes, CacheError] {
  let entry = match self.readable(now_monotonic_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let body = encode_status(
    entry.sample,
    now_monotonic_ms,
    self.snapshot_max_age_ms.to_int64(),
    self.snapshot_max_age_ms.to_int64(),
    driver_progress_override=self.latest_driver_progress_ms,
    details_enabled~,
    operations_enabled~,
    details_available~,
    reload_enabled~,
  )
  if body.length() > self.config.max_response_bytes() {
    return Err(ResponseTooLarge)
  }
  Ok(body)
}

///|
pub fn ObservationCache::metrics_body(
  self : ObservationCache,
  now_monotonic_ms : Int64,
) -> Result[Bytes, CacheError] {
  let entry = match self.readable(now_monotonic_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match entry.metrics_body {
    None => Err(Unavailable)
    Some(body) => Ok(Bytes::from_array(body.to_array()))
  }
}

///|
/// Render ages at request time from the cached scalar snapshot and the
/// separately advanced driver heartbeat. No broker Map or payload is read.
pub fn ObservationCache::render_metrics(
  self : ObservationCache,
  now_monotonic_ms : Int64,
  rejections : ManagementRejections,
) -> Result[Bytes, CacheError] {
  let entry = match self.readable(now_monotonic_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let body = match
    render_prometheus(
      entry.sample,
      now_monotonic_ms,
      self.latest_driver_progress_ms,
      rejections,
    ) {
    Ok(value) => value
    Err(_) => return Err(Stale)
  }
  if body.length() > self.config.max_response_bytes() {
    return Err(ResponseTooLarge)
  }
  Ok(body)
}

///|
/// Withdraw readiness before the acceptor is cancelled. Existing health
/// requests can still report live while no new work is admitted.
pub fn ObservationCache::mark_stopping(self : ObservationCache) -> Unit {
  self.stopping = true
}

///|
pub fn ObservationCache::close(self : ObservationCache) -> Unit {
  if !self.closed {
    self.closed = true
    self.current = None
    self.owner.release_cache()
  }
}
