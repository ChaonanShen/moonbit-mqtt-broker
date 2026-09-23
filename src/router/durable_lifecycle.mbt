///|
pub(all) enum DurableLifecycleKind {
  DetachAt(Int64)
  SetDetachedAt(Int64)
  Delete
} derive(Eq, Debug)

///|
pub struct DurableLifecyclePlan {
  broker : BrokerState
  client_id : @session.ClientId
  candidate : @session.ClientSession?
  before_inflight : Int
  before_pending : Int
  before_inbound : Int
  before_revision : Int64
  mut admin_handle : Int64?
  mut admin_version : Int64?
  persistent : Bool
  scratch : @budget.Ticket
  delta : DurableDelta
  action : BrokerAction
  mut finished : Bool
}

///|
pub fn DurableLifecyclePlan::delta(self : DurableLifecyclePlan) -> DurableDelta {
  self.delta
}

///|
pub fn BrokerState::prepare_durable_lifecycle(
  self : BrokerState,
  client_id : @session.ClientId,
  generation : Int64,
  kind : DurableLifecycleKind,
) -> Result[DurableLifecyclePlan, RouterError] {
  let old = match self.sessions.get(client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(client_id))
  }
  if generation < 1L {
    return Err(InvariantViolation("invalid durable lifecycle generation"))
  }
  let scratch = match self.reserve_scratch(old.state_bytes() * 2L + 128L) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let persistent = old.mode() == @session.SessionMode::Persistent
  let (candidate, action, delta) = match kind {
    DetachAt(detached_at_ms) => {
      if !old.is_attached() || detached_at_ms < 0L {
        scratch.release().unwrap()
        return Err(InvalidSessionState(client_id))
      }
      let candidate = old.copy()
      candidate.detach(detached_at_ms~)
      let delta = if persistent {
        DurableDelta::{
          session_puts: [
            {
              expected_generation: generation,
              generation,
              session: self.snapshot_session_candidate(client_id, candidate),
            },
          ],
          session_deletes: [],
          retained_puts: [],
          retained_deletes: [],
        }
      } else {
        DurableDelta::empty()
      }
      (Some(candidate), SessionDetached(client_id), delta)
    }
    SetDetachedAt(detached_at_ms) => {
      if old.mode() != @session.Persistent ||
        old.is_attached() ||
        old.detached_at_ms() != Some(0L) ||
        detached_at_ms < 0L {
        scratch.release().unwrap()
        return Err(InvalidSessionState(client_id))
      }
      let candidate = old.copy()
      candidate.detach(detached_at_ms~)
      let delta = DurableDelta::{
        session_puts: [
          {
            expected_generation: generation,
            generation,
            session: self.snapshot_session_candidate(client_id, candidate),
          },
        ],
        session_deletes: [],
        retained_puts: [],
        retained_deletes: [],
      }
      (Some(candidate), SessionDetached(client_id), delta)
    }
    Delete => {
      let delta = if persistent {
        DurableDelta::{
          session_puts: [],
          session_deletes: [
            { client_id: client_id.value(), expected_generation: generation },
          ],
          retained_puts: [],
          retained_deletes: [],
        }
      } else {
        DurableDelta::empty()
      }
      (None, SessionRemoved(client_id), delta)
    }
  }
  Ok({
    broker: self,
    client_id,
    candidate,
    before_inflight: old.inflight_count(),
    before_pending: old.pending_count(),
    before_inbound: old.inbound_qos2_count(),
    before_revision: self.snapshot_revision(),
    admin_handle: None,
    admin_version: None,
    persistent,
    scratch,
    delta,
    action,
    finished: false,
  })
}

///|
pub fn DurableLifecyclePlan::commit(
  self : DurableLifecyclePlan,
) -> Result[Array[BrokerAction], RouterError] {
  if self.finished || self.broker.snapshot_revision() != self.before_revision {
    return Err(InvariantViolation("durable lifecycle owner changed"))
  }
  if self.admin_handle is Some(handle) && self.admin_version is Some(version) {
    let index = match self.broker.admin_sessions {
      Some(value) if value.available() => value
      _ =>
        return Err(
          InvariantViolation("admin delete index unavailable at commit"),
        )
    }
    match index.identity_for_handle(handle) {
      Some(identity) if identity.client_id == self.client_id &&
        identity.lifecycle_version == version => ()
      _ => return Err(InvariantViolation("admin delete lifecycle changed"))
    }
  }
  match self.candidate {
    Some(candidate) => {
      self.broker.sessions.set(self.client_id, candidate)
      if self.broker.admin_sessions is Some(index) {
        index.bump(self.client_id)
      }
    }
    None => {
      let owner = self.broker.resources.owners.get(self.client_id).unwrap()
      if owner.ticket.release() is Err(_) {
        return Err(InvariantViolation("durable lifecycle budget owner changed"))
      }
      self.broker.resources.owners.remove(self.client_id)
      if self.broker.admin_sessions is Some(index) {
        index.remove_all_subscriptions(self.client_id)
      }
      ignore(self.broker.subscriptions.remove_all(self.client_id))
      self.broker.sessions.remove(self.client_id)
      if self.broker.admin_sessions is Some(index) {
        index.remove(self.client_id)
      }
      self.broker.inflight_total -= self.before_inflight
      self.broker.pending_qos1_total -= self.before_pending
      self.broker.inbound_qos2_total -= self.before_inbound
    }
  }
  if self.persistent {
    self.broker.mark_snapshot_dirty()
  }
  self.finished = true
  self.scratch.release().unwrap()
  Ok([self.action])
}

///|
pub fn DurableLifecyclePlan::cancel(self : DurableLifecyclePlan) -> Unit {
  if !self.finished {
    self.scratch.release().unwrap()
    self.finished = true
  }
}
