///|
pub(all) enum ReloadSource {
  LocalSignal
  Management
} derive(Eq, Debug)

///|
pub(all) struct ReloadRequest {
  id : Int64
  source : ReloadSource
  base_epoch : Int64
  expected_epoch : Int64?
} derive(Eq, Debug)

///|
pub(all) enum ReloadAdmission {
  ReloadStarted(Int64)
  ReloadQueued(Int64)
  ReloadCoalesced
  ReloadBusy
  ReloadDisabled
  ReloadStale
} derive(Eq, Debug)

///|
/// The bounded admission portion of the reload coordinator. Only the active
/// request can prepare or activate; the sole waiting slot is held until the
/// active request reaches a terminal state and its resources are reaped.
pub struct ReloadRequests {
  enabled : Bool
  mut next_id : Int64
  mut active : ReloadRequest?
  mut waiting : ReloadRequest?
}

///|
pub fn ReloadRequests::new(enabled : Bool) -> ReloadRequests {
  { enabled, next_id: 1L, active: None, waiting: None }
}

///|
fn ReloadRequests::allocate(
  self : ReloadRequests,
  source : ReloadSource,
  base_epoch : Int64,
  expected_epoch : Int64?,
) -> ReloadRequest? {
  if self.next_id < 1L || self.next_id == 9223372036854775807L {
    return None
  }
  let request = { id: self.next_id, source, base_epoch, expected_epoch }
  self.next_id += 1L
  Some(request)
}

///|
pub fn ReloadRequests::signal(
  self : ReloadRequests,
  current_epoch : Int64,
) -> ReloadAdmission {
  if !self.enabled {
    return ReloadDisabled
  }
  if self.active is Some(_) {
    if self.waiting is Some(value) {
      if value.source == LocalSignal {
        return ReloadCoalesced
      }
      return ReloadBusy
    }
    let request = match self.allocate(LocalSignal, current_epoch, None) {
      Some(value) => value
      None => return ReloadBusy
    }
    self.waiting = Some(request)
    return ReloadQueued(request.id)
  }
  let request = match self.allocate(LocalSignal, current_epoch, None) {
    Some(value) => value
    None => return ReloadBusy
  }
  self.active = Some(request)
  ReloadStarted(request.id)
}

///|
pub fn ReloadRequests::management(
  self : ReloadRequests,
  expected_epoch : Int64,
  current_epoch : Int64,
) -> ReloadAdmission {
  if !self.enabled {
    return ReloadDisabled
  }
  if expected_epoch != current_epoch {
    return ReloadStale
  }
  if self.active is Some(_) && self.waiting is Some(_) {
    return ReloadBusy
  }
  let request = match
    self.allocate(Management, current_epoch, Some(expected_epoch)) {
    Some(value) => value
    None => return ReloadBusy
  }
  if self.active is None {
    self.active = Some(request)
    ReloadStarted(request.id)
  } else {
    self.waiting = Some(request)
    ReloadQueued(request.id)
  }
}

///|
pub fn ReloadRequests::active(self : ReloadRequests) -> ReloadRequest? {
  self.active
}

///|
/// Rechecks a management precondition at the durable publication boundary.
pub fn ReloadRequests::can_activate(
  self : ReloadRequests,
  id : Int64,
  current_epoch : Int64,
) -> Bool {
  match self.active {
    Some(request) if request.id == id =>
      match request.expected_epoch {
        Some(value) => value == current_epoch
        None => request.base_epoch == current_epoch
      }
    _ => false
  }
}

///|
/// The caller invokes this only after a terminal result and true native reap.
/// A queued signal observes the current generation when it becomes active.
pub fn ReloadRequests::finish_active(
  self : ReloadRequests,
  id : Int64,
  current_epoch : Int64,
) -> ReloadRequest? {
  match self.active {
    Some(request) if request.id == id => ()
    _ => return None
  }
  let next = self.waiting
  self.waiting = None
  self.active = next.map(value => {
    if value.source == LocalSignal {
      { ..value, base_epoch: current_epoch }
    } else {
      value
    }
  })
  self.active
}

///|
/// Roll back an admission before it starts when its operation record could not
/// be reserved. No active worker or native token may exist at this point.
pub fn ReloadRequests::cancel_unstarted(
  self : ReloadRequests,
  id : Int64,
) -> Bool {
  match self.waiting {
    Some(value) if value.id == id => {
      self.waiting = None
      return true
    }
    _ => ()
  }
  match self.active {
    Some(value) if value.id == id => {
      self.active = None
      return true
    }
    _ => false
  }
}
