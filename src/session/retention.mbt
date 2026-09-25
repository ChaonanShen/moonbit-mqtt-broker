///|
pub(all) enum Retention {
  DropOnClose
  LegacyBrokerPolicy
  FiniteV5(UInt)
  InfiniteV5
} derive(Eq, Debug)

///|
pub(all) enum ResumeDecision {
  StartFresh
  ResumeExisting
} derive(Eq, Debug)

///|
pub(all) struct Deadline {
  mono_due_ms : Int64
  wall_due_ms : Int64
  saved_remaining_ms : Int64
} derive(Eq, Debug)

///|
pub(all) enum RetentionError {
  InvalidClock
  ClockOverflow
  InvalidExpiryOverride
} derive(Eq, Debug)

///|
pub fn retention_from_connect(expiry_seconds : UInt) -> Retention {
  if expiry_seconds == 0U {
    DropOnClose
  } else if expiry_seconds == 0xffffffffU {
    InfiniteV5
  } else {
    FiniteV5(expiry_seconds)
  }
}

///|
pub fn resume_from_clean_start(clean_start : Bool) -> ResumeDecision {
  if clean_start {
    StartFresh
  } else {
    ResumeExisting
  }
}

///|
pub fn retention_from_disconnect(
  connected : Retention,
  expiry_seconds : UInt,
) -> Result[Retention, RetentionError] {
  if connected == DropOnClose && expiry_seconds != 0U {
    return Err(InvalidExpiryOverride)
  }
  Ok(retention_from_connect(expiry_seconds))
}

///|
pub fn Deadline::new(
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  remaining_ms : Int64,
) -> Result[Deadline, RetentionError] {
  if now_mono_ms < 0L || now_wall_ms < 0L || remaining_ms < 0L {
    return Err(InvalidClock)
  }
  let mono_due_ms = match @budget.checked_add(now_mono_ms, remaining_ms) {
    Ok(value) => value
    Err(_) => return Err(ClockOverflow)
  }
  let wall_due_ms = match @budget.checked_add(now_wall_ms, remaining_ms) {
    Ok(value) => value
    Err(_) => return Err(ClockOverflow)
  }
  Ok({ mono_due_ms, wall_due_ms, saved_remaining_ms: remaining_ms })
}

///|
pub fn Deadline::from_seconds(
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  seconds : UInt,
) -> Result[Deadline, RetentionError] {
  let remaining_ms = match @budget.checked_mul(seconds.to_int64(), 1000L) {
    Ok(value) => value
    Err(_) => return Err(ClockOverflow)
  }
  Deadline::new(now_mono_ms, now_wall_ms, remaining_ms)
}

///|
pub fn Deadline::remaining_at(self : Deadline, now_mono_ms : Int64) -> Int64 {
  if now_mono_ms >= self.mono_due_ms {
    0L
  } else {
    self.mono_due_ms - now_mono_ms
  }
}

///|
/// Clamp recovery to both the persisted remaining amount and elapsed wall time.
pub fn Deadline::restore(
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  persisted_floor_wall_ms : Int64,
  saved_remaining_ms : Int64,
  deadline_wall_ms : Int64,
) -> Result[Deadline, RetentionError] {
  if now_mono_ms < 0L ||
    now_wall_ms < 0L ||
    persisted_floor_wall_ms < 0L ||
    saved_remaining_ms < 0L ||
    deadline_wall_ms < 0L {
    return Err(InvalidClock)
  }
  let effective_wall = if now_wall_ms < persisted_floor_wall_ms {
    persisted_floor_wall_ms
  } else {
    now_wall_ms
  }
  let by_wall = if deadline_wall_ms <= effective_wall {
    0L
  } else {
    deadline_wall_ms - effective_wall
  }
  let remaining = if saved_remaining_ms < by_wall {
    saved_remaining_ms
  } else {
    by_wall
  }
  Deadline::new(now_mono_ms, effective_wall, remaining)
}
