///|
/// Owns one reference to each active TLS material lease. Handshakes and
/// established transports hold separate references until their task exits.
pub struct TlsMaterialProvider {
  mut active : Map[String, TlsMaterialLease]
  mut closed : Bool
}

///|
fn TlsMaterialProvider::new() -> TlsMaterialProvider {
  { active: Map([]), closed: false }
}

///|
fn TlsMaterialProvider::add_initial(
  self : TlsMaterialProvider,
  listener_id : String,
  lease : TlsMaterialLease,
) -> Unit {
  if self.closed || self.active.contains(listener_id) {
    abort("invalid initial TLS material provider state")
  }
  self.active.set(listener_id, lease)
}

///|
fn TlsMaterialProvider::acquire(
  self : TlsMaterialProvider,
  listener_id : String,
) -> TlsMaterialLease? {
  if self.closed {
    return None
  }
  match self.active.get(listener_id) {
    Some(lease) => {
      lease.retain()
      Some(lease)
    }
    None => None
  }
}

///|
fn TlsMaterialProvider::close(self : TlsMaterialProvider) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for _, lease in self.active {
    lease.release()
  }
  self.active.clear()
}

///|
/// Preflight a complete replacement without taking candidate ownership.
pub fn TlsMaterialProvider::can_publish_generation(
  self : TlsMaterialProvider,
  candidates : Array[(String, TlsMaterialLease)],
) -> Bool {
  if self.closed || candidates.length() != self.active.length() {
    return false
  }
  let seen : Map[String, Bool] = Map([])
  let directories : Map[String, Bool] = Map([])
  for item in candidates {
    let (listener_id, lease) = item
    let old = match self.active.get(listener_id) {
      Some(value) => value
      None => return false
    }
    if seen.contains(listener_id) ||
      old.directory == lease.directory ||
      directories.contains(lease.directory) {
      return false
    }
    seen.set(listener_id, true)
    directories.set(lease.directory, true)
  }
  true
}

///|
/// Swaps the entire prepared TLS generation at one non-awaiting event boundary.
/// Rejection leaves all candidate leases owned by the caller.
pub fn TlsMaterialProvider::publish_generation(
  self : TlsMaterialProvider,
  candidates : Array[(String, TlsMaterialLease)],
) -> Bool {
  if !self.can_publish_generation(candidates) {
    return false
  }
  let next : Map[String, TlsMaterialLease] = Map([])
  for item in candidates {
    let (listener_id, lease) = item
    next.set(listener_id, lease)
  }
  let old = self.active
  self.active = next
  for _, lease in old {
    lease.release()
  }
  true
}

///|
fn TlsMaterialProvider::current_config(
  self : TlsMaterialProvider,
  listener_id : String,
) -> TlsServerConfig? {
  match self.active.get(listener_id) {
    Some(lease) => Some(lease.config)
    None => None
  }
}
