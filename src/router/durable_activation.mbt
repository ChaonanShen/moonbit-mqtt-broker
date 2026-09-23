///|
pub struct DurableActivationPlan {
  broker : BrokerState
  client_id : @session.ClientId
  candidate : @session.ClientSession
  before_revision : Int64
  old_inflight : Int
  old_pending : Int
  old_inbound : Int
  persistent_changed : Bool
  reset : Bool
  session_present : Bool
  desired_inflight : Int64
  desired_pending : Int64
  desired_inbound : Int64
  desired_metadata : Int64
  desired_subscriptions : Int64
  replacement : @budget.Replacement?
  new_owner_pools : Array[@budget.Pool]
  new_owner_ticket : @budget.Ticket?
  scratch : @budget.Ticket
  replay : Array[BrokerAction]
  delta : DurableDelta
  mut finished : Bool
}

///|
pub fn DurableActivationPlan::session_present(
  self : DurableActivationPlan,
) -> Bool {
  self.session_present
}

///|
pub fn DurableActivationPlan::delta(
  self : DurableActivationPlan,
) -> DurableDelta {
  self.delta
}

///|
pub fn BrokerState::prepare_durable_activation(
  self : BrokerState,
  id : @session.ClientId,
  mode : @session.SessionMode,
  owner : @security.Principal,
  old_generation : Int64,
  new_generation : Int64,
) -> Result[DurableActivationPlan, RouterError] {
  let old = self.sessions.get(id)
  if old is None && self.sessions.length() >= self.config.max_sessions() {
    return Err(SessionLimitReached(self.config.max_sessions()))
  }
  let restoring = mode == @session.Persistent &&
    old is Some(value) &&
    value.mode() == @session.Persistent
  let old_persistent = old is Some(value) && value.mode() == @session.Persistent
  if (old_persistent && old_generation < 1L) ||
    (mode == @session.Persistent && new_generation < 1L) ||
    (restoring && new_generation != old_generation) {
    return Err(InvariantViolation("invalid durable activation generation"))
  }
  let desired : ResourceUsage = if restoring {
    self.resources.owners.get(id).unwrap().usage
  } else {
    {
      inflight: 0L,
      pending: 0L,
      inbound: 0L,
      subscriptions: 0L,
      metadata: @budget.identity_cost(id.value(), owner.storage_value()),
    }
  }
  let old_cost = old.map(value => value.state_bytes()).unwrap_or(0L)
  let old_subscriptions = self.resources.owners
    .get(id)
    .map(value => value.usage.subscriptions)
    .unwrap_or(0L)
  let scratch = match
    self.reserve_scratch(
      old_cost * 6L + old_subscriptions * 2L + desired.metadata + 128L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (candidate, deliveries) = if restoring {
    let candidate = old.unwrap().copy()
    candidate.detach()
    let deliveries = match
      candidate.attach(self.session_limits(max_inflight=0)) {
      Ok(value) => value
      Err(error) => {
        scratch.release().unwrap()
        return Err(SessionFailure(error))
      }
    }
    (candidate, deliveries)
  } else {
    (@session.ClientSession::new(id, mode~, attached=true, owner~), [])
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
          Deliver({
            recipient: id,
            topic: message.topic,
            payload: copy_router_bytes(message.payload),
            qos: message.qos,
            retain: message.retain,
            packet_id: Some(delivery.packet_id),
            dup: true,
          }),
        )
    }
  }
  let mut new_owner_pools : Array[@budget.Pool] = []
  let mut new_owner_ticket : @budget.Ticket? = None
  let replacement = match self.resources.owners.get(id) {
    Some(resource) =>
      match
        self.resources.ledger.prepare_deferred_replacement([
          (resource.ticket, resource.allocations(desired)),
        ]) {
        Ok(value) => Some(value)
        Err(error) => {
          scratch.release().unwrap()
          return Err(ByteResourceLimit(error))
        }
      }
    None => {
      let new_owner = match self.resources.prepare_owner(desired) {
        Ok(value) => value
        Err(error) => {
          scratch.release().unwrap()
          return Err(error)
        }
      }
      new_owner_pools = new_owner.pools
      new_owner_ticket = Some(new_owner.ticket)
      None
    }
  }
  let delta = if mode == @session.Persistent {
    DurableDelta::{
      session_puts: [
        {
          expected_generation: if old_persistent {
            old_generation
          } else {
            0L
          },
          generation: new_generation,
          session: self.snapshot_session_candidate(id, candidate),
        },
      ],
      session_deletes: [],
      retained_puts: [],
      retained_deletes: [],
    }
  } else if old_persistent {
    DurableDelta::{
      session_puts: [],
      session_deletes: [
        { client_id: id.value(), expected_generation: old_generation },
      ],
      retained_puts: [],
      retained_deletes: [],
    }
  } else {
    DurableDelta::empty()
  }
  Ok({
    broker: self,
    client_id: id,
    candidate,
    before_revision: self.snapshot_revision(),
    old_inflight: old.map(value => value.inflight_count()).unwrap_or(0),
    old_pending: old.map(value => value.pending_count()).unwrap_or(0),
    old_inbound: old.map(value => value.inbound_qos2_count()).unwrap_or(0),
    persistent_changed: mode == @session.Persistent || old_persistent,
    reset: !restoring,
    session_present: restoring,
    desired_inflight: desired.inflight,
    desired_pending: desired.pending,
    desired_inbound: desired.inbound,
    desired_metadata: desired.metadata,
    desired_subscriptions: desired.subscriptions,
    replacement,
    new_owner_pools,
    new_owner_ticket,
    scratch,
    replay,
    delta,
    finished: false,
  })
}

///|
pub fn DurableActivationPlan::commit(
  self : DurableActivationPlan,
) -> Result[Array[BrokerAction], RouterError] {
  if self.finished || self.broker.snapshot_revision() != self.before_revision {
    return Err(InvariantViolation("durable activation state changed"))
  }
  if self.replacement is Some(value) {
    match value.commit() {
      Ok(_) => ()
      Err(_) =>
        return Err(InvariantViolation("durable activation owner changed"))
    }
  }
  let desired : ResourceUsage = {
    inflight: self.desired_inflight,
    pending: self.desired_pending,
    inbound: self.desired_inbound,
    metadata: self.desired_metadata,
    subscriptions: self.desired_subscriptions,
  }
  if self.new_owner_ticket is Some(ticket) {
    match ticket.commit() {
      Ok(_) => ()
      Err(_) =>
        return Err(InvariantViolation("durable activation new owner changed"))
    }
    self.broker.resources.owners.set(self.client_id, OwnerResources::{
      pools: self.new_owner_pools,
      ticket,
      usage: desired,
    })
  } else {
    self.broker.resources.owners.get(self.client_id).unwrap().usage = desired
  }
  let old = self.broker.sessions.get(self.client_id)
  if old is Some(value) {
    self.broker.inflight_total -= value.inflight_count()
    self.broker.pending_qos1_total -= value.pending_count()
    self.broker.inbound_qos2_total -= value.inbound_qos2_count()
  }
  if self.reset {
    if self.broker.admin_sessions is Some(index) {
      index.remove_all_subscriptions(self.client_id)
    }
    ignore(self.broker.subscriptions.remove_all(self.client_id))
  }
  self.broker.sessions.set(self.client_id, self.candidate)
  if self.broker.admin_sessions is Some(index) {
    if old is None {
      index.register(self.client_id)
    } else if self.reset {
      index.replace(self.client_id)
    } else {
      index.bump(self.client_id)
    }
  }
  self.broker.inflight_total += self.candidate.inflight_count()
  self.broker.pending_qos1_total += self.candidate.pending_count()
  self.broker.inbound_qos2_total += self.candidate.inbound_qos2_count()
  if self.persistent_changed {
    self.broker.mark_snapshot_dirty()
  }
  self.finished = true
  self.broker.retain_action_lease(self.scratch)
  Ok(self.replay)
}

///|
pub fn DurableActivationPlan::cancel(self : DurableActivationPlan) -> Unit {
  if !self.finished {
    if self.replacement is Some(value) {
      value.rollback().unwrap()
    }
    if self.new_owner_ticket is Some(ticket) {
      ticket.release().unwrap()
    }
    self.scratch.release().unwrap()
    self.finished = true
  }
}
