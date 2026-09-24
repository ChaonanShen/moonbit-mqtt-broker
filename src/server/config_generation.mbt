///|
/// Immutable publication metadata. Runtime components keep their own leases;
/// the ledger ticket remains with this root until its caller confirms the old
/// generation has no policy references.
pub struct ConfigGeneration {
  config_epoch : Int64
  policy_epoch : Int64
  bundle : @bundle.CapturedBundle
  effective : @bundle.ReloadEffectiveCandidate
  security : @security.SecurityPolicy
  fingerprint : Bytes
  budget : @budget.Ticket?
  mut released : Bool
}

///|
pub fn ConfigGeneration::initial(
  bundle : @bundle.CapturedBundle,
  effective : @bundle.ReloadEffectiveCandidate,
  security : @security.SecurityPolicy,
  fingerprint : Bytes,
  policy_epoch? : Int64 = 0L,
) -> ConfigGeneration {
  {
    config_epoch: 0L,
    policy_epoch,
    bundle,
    effective,
    security,
    fingerprint,
    budget: None,
    released: false,
  }
}

///|
pub fn ConfigGeneration::config_epoch(self : ConfigGeneration) -> Int64 {
  self.config_epoch
}

///|
pub fn ConfigGeneration::policy_epoch(self : ConfigGeneration) -> Int64 {
  self.policy_epoch
}

///|
pub fn ConfigGeneration::release(self : ConfigGeneration) -> Unit {
  if self.released {
    return
  }
  self.released = true
  if self.budget is Some(ticket) {
    ticket.release().unwrap()
  }
}

///|
pub struct GenerationHandle {
  mut active : ConfigGeneration
  mut closed : Bool
}

///|
pub fn GenerationHandle::new(initial : ConfigGeneration) -> GenerationHandle {
  { active: initial, closed: false }
}

///|
pub fn GenerationHandle::active(self : GenerationHandle) -> ConfigGeneration {
  self.active
}

///|
/// Called after all other non-failing runtime publications at one driver
/// boundary. The caller owns the returned old root until its references drain.
pub fn GenerationHandle::publish(
  self : GenerationHandle,
  prepared : PreparedReload,
  expected_epoch : Int64,
) -> ConfigGeneration? {
  if self.closed ||
    self.active.config_epoch != expected_epoch ||
    prepared.released ||
    self.active.config_epoch == 9223372036854775807L ||
    self.active.policy_epoch == 9223372036854775807L ||
    (prepared.tls is Some(value) && !value.transferred) {
    return None
  }
  let policy_epoch = if prepared.security_changed {
    self.active.policy_epoch + 1L
  } else {
    self.active.policy_epoch
  }
  let next : ConfigGeneration = {
    config_epoch: self.active.config_epoch + 1L,
    policy_epoch,
    bundle: prepared.bundle,
    effective: prepared.effective,
    security: prepared.security,
    fingerprint: prepared.fingerprint,
    budget: Some(prepared.budget),
    released: false,
  }
  prepared.released = true
  let old = self.active
  self.active = next
  Some(old)
}

///|
pub fn GenerationHandle::close(self : GenerationHandle) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.active.release()
}
