///|
pub struct SnapshotSchedule {
  debounce_ms : Int64
  max_delay_ms : Int64
  mut last_observed_revision : Int64
  mut last_submitted_revision : Int64
  mut dirty_since_ms : Int64?
  mut last_change_ms : Int64?
}

///|
pub fn SnapshotSchedule::new(
  initial_revision : Int64,
  debounce_ms : Int64,
  max_delay_ms : Int64,
) -> Result[SnapshotSchedule, @persistence.PersistenceError] {
  if debounce_ms < 1L || max_delay_ms < debounce_ms {
    return Err(
      @persistence.PersistenceError::InvalidConfiguration(
        "invalid snapshot schedule timing",
      ),
    )
  }
  Ok({
    debounce_ms,
    max_delay_ms,
    last_observed_revision: initial_revision,
    last_submitted_revision: initial_revision,
    dirty_since_ms: None,
    last_change_ms: None,
  })
}

///|
pub fn SnapshotSchedule::observe(
  self : SnapshotSchedule,
  revision : Int64,
  now_ms : Int64,
) -> Unit {
  if revision > self.last_observed_revision {
    if self.dirty_since_ms is None {
      self.dirty_since_ms = Some(now_ms)
    }
    self.last_change_ms = Some(now_ms)
    self.last_observed_revision = revision
  }
}

///|
pub fn SnapshotSchedule::due_revision(
  self : SnapshotSchedule,
  now_ms : Int64,
) -> Int64? {
  guard self.last_observed_revision > self.last_submitted_revision &&
    self.dirty_since_ms is Some(dirty_since) &&
    self.last_change_ms is Some(last_change) else {
    return None
  }
  if now_ms - last_change >= self.debounce_ms ||
    now_ms - dirty_since >= self.max_delay_ms {
    Some(self.last_observed_revision)
  } else {
    None
  }
}

///|
pub fn SnapshotSchedule::force_revision(self : SnapshotSchedule) -> Int64? {
  if self.last_observed_revision > self.last_submitted_revision {
    Some(self.last_observed_revision)
  } else {
    None
  }
}

///|
pub fn SnapshotSchedule::mark_submitted(
  self : SnapshotSchedule,
  revision : Int64,
) -> Unit {
  if revision > self.last_submitted_revision {
    self.last_submitted_revision = revision
  }
  if revision >= self.last_observed_revision {
    self.dirty_since_ms = None
    self.last_change_ms = None
  }
}

///|
pub fn SnapshotSchedule::last_submitted_revision(
  self : SnapshotSchedule,
) -> Int64 {
  self.last_submitted_revision
}
