///|
/// Owns one reference to each active TLS material lease. Handshakes and
/// established transports hold separate references until their task exits.
pub struct TlsMaterialProvider {
  active : Map[String, TlsMaterialLease]
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
/// Publishes a fully prepared lease for an existing listener. The caller owns
/// a rejected candidate; on success the provider takes its root reference.
pub fn TlsMaterialProvider::publish_prepared(
  self : TlsMaterialProvider,
  listener_id : String,
  candidate : TlsMaterialLease,
) -> Bool {
  if self.closed || !self.active.contains(listener_id) {
    return false
  }
  let old = self.active.get(listener_id).unwrap()
  self.active.set(listener_id, candidate)
  old.release()
  true
}
