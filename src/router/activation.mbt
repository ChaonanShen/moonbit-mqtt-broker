///|
pub struct SessionActivation {
  priv broker : BrokerState
  priv id : @session.ClientId
  priv session : @session.ClientSession
  priv usage : ResourceUsage
  priv replay : Array[BrokerAction]
  priv replacement : @budget.Replacement?
  priv scratch : @budget.Ticket
  priv reset : Bool
  priv new_owner : Bool
  priv mut finished : Bool
}

///|
pub fn SessionActivation::session_present(self : SessionActivation) -> Bool {
  !self.reset
}

///|
/// Prepare all fallible allocation/admission before retiring the old transport.
/// The caller must commit or cancel before another broker mutation (no await).
pub fn BrokerState::prepare_activation(
  self : BrokerState,
  id : @session.ClientId,
  mode : @session.SessionMode,
  owner : @security.Principal,
  v5_resume? : Bool = false,
  v5_retention? : @session.Retention,
  now_mono_ms? : Int64 = 0L,
) -> Result[SessionActivation, RouterError] {
  let old = self.sessions.get(id)
  if old is None && self.sessions.length() >= self.config.max_sessions() {
    return Err(SessionLimitReached(self.config.max_sessions()))
  }
  let restoring = if v5_retention is Some(_) {
    v5_resume && old is Some(s) && !s.logically_expired(now_mono_ms)
  } else {
    mode == @session.SessionMode::Persistent &&
    old is Some(s) &&
    s.mode() == @session.SessionMode::Persistent
  }
  let old_usage = self.resources.owners.get(id).map(r => r.usage)
  let desired = if restoring {
    old_usage.unwrap()
  } else {
    ResourceUsage::{
      inflight: 0L,
      pending: 0L,
      inbound: 0L,
      subscriptions: 0L,
      metadata: @budget.identity_cost(id.value(), owner.storage_value()),
    }
  }
  let old_cost = old.map(s => s.state_bytes()).unwrap_or(0L)
  let subscriptions = old_usage.map(u => u.subscriptions).unwrap_or(0L)
  let scratch = match
    self.reserve_scratch(
      old_cost * 6L + subscriptions * 2L + desired.metadata + 128L,
    ) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let mut succeeded = false
  defer (if !succeeded { scratch.release().unwrap() })
  let (session, deliveries) = if restoring {
    let session = old.unwrap().copy()
    session.detach()
    let deliveries = session
      .attach(
        self.session_limits(max_inflight=0),
        pubrel_first=v5_retention is Some(_),
      )
      .unwrap()
    (
      if v5_retention is Some(retention) {
        session.with_retention(retention)
      } else {
        session
        .with_retention(@session.LegacyBrokerPolicy)
        .with_last_protocol(4)
      },
      deliveries,
    )
  } else {
    (
      if v5_retention is Some(retention) {
        @session.ClientSession::new_with_retention(
          id,
          retention,
          attached=true,
          owner~,
        )
      } else {
        @session.ClientSession::new(id, mode~, attached=true, owner~)
      },
      [],
    )
  }
  let replay : Array[BrokerAction] = []
  for delivery in deliveries {
    match delivery.message {
      None =>
        replay.push(
          SendPubrel({ client_id: id, packet_id: delivery.packet_id }),
        )
      Some(message) =>
        replay.push(
          delivery_with_metadata(
            {
              recipient: id,
              topic: message.topic,
              payload: copy_router_bytes(message.payload),
              qos: message.qos,
              retain: message.retain,
              packet_id: Some(delivery.packet_id),
              dup: true,
            },
            message.metadata,
            message.subscription_identifiers,
          ),
        )
    }
  }
  let replacement = match self.resources.owners.get(id) {
    Some(resource) =>
      match
        self.resources.ledger.prepare_replacement([
          (resource.ticket, resource.allocations(desired)),
        ]) {
        Ok(tx) => Some(tx)
        Err(e) => return Err(ByteResourceLimit(e))
      }
    None => {
      match self.resources.add_owner(id, desired) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      None
    }
  }
  succeeded = true
  Ok({
    broker: self,
    id,
    session,
    usage: desired,
    replay,
    replacement,
    scratch,
    reset: !restoring,
    new_owner: old is None,
    finished: false,
  })
}

///|
pub fn BrokerState::commit_activation(
  self : BrokerState,
  activation : SessionActivation,
) -> Result[Array[BrokerAction], RouterError] {
  if activation.finished || !physical_equal(activation.broker, self) {
    return Err(InvariantViolation("invalid session activation"))
  }
  let old = self.sessions.get(activation.id)
  let persistent_changed = activation.session.mode() ==
    @session.SessionMode::Persistent ||
    (old is Some(s) && s.mode() == @session.SessionMode::Persistent)
  if old is Some(s) {
    self.inflight_total -= s.inflight_count()
    self.pending_qos1_total -= s.pending_count()
    self.inbound_qos2_total -= s.inbound_qos2_count()
  }
  if activation.reset {
    if self.admin_sessions is Some(index) {
      index.remove_all_subscriptions(activation.id)
    }
    ignore(self.subscriptions.remove_all(activation.id))
  }
  self.track_policy_session(activation.id)
  if old is None || activation.reset {
    self.assign_session_incarnation(activation.id)
  }
  if old is Some(_) && activation.reset {
    self.replace_policy_session(activation.id)
  }
  self.sessions.set(activation.id, activation.session)
  if self.admin_sessions is Some(index) {
    if old is None {
      index.register(activation.id)
    } else if activation.reset {
      index.replace(activation.id)
    } else {
      index.bump(activation.id)
    }
  }
  self.inflight_total += activation.session.inflight_count()
  self.pending_qos1_total += activation.session.pending_count()
  self.inbound_qos2_total += activation.session.inbound_qos2_count()
  if activation.replacement is Some(tx) {
    tx.commit().unwrap()
  }
  self.resources.owners.get(activation.id).unwrap().usage = activation.usage
  activation.finished = true
  if persistent_changed {
    self.mark_snapshot_dirty()
  }
  self.retain_action_lease(activation.scratch)
  Ok(activation.replay)
}

///|
pub fn BrokerState::cancel_activation(
  self : BrokerState,
  activation : SessionActivation,
) -> Result[Unit, RouterError] {
  if activation.finished || !physical_equal(activation.broker, self) {
    return Err(InvariantViolation("invalid session activation"))
  }
  if activation.replacement is Some(tx) {
    tx.rollback().unwrap()
  }
  if activation.new_owner {
    self.resources.owners.get(activation.id).unwrap().ticket.release().unwrap()
    self.resources.owners.remove(activation.id)
  }
  activation.scratch.release().unwrap()
  activation.finished = true
  Ok(())
}
