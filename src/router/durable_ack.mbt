///|
pub(all) enum DurableAckKind {
  OutboundPuback
  OutboundPubrec
  OutboundPubcomp
  InboundPubrel
} derive(Eq, Debug)

///|
pub struct DurableAckPlan {
  broker : BrokerState
  client_id : @session.ClientId
  candidate : @session.ClientSession
  before_inflight : Int
  before_pending : Int
  before_inbound : Int
  inflight_bytes : Int64
  pending_bytes : Int64
  inbound_bytes : Int64
  metadata_bytes : Int64
  subscription_bytes : Int64
  replacement : @budget.Replacement?
  scratch : @budget.Ticket
  actions : Array[BrokerAction]
  delta : DurableDelta
  changed : Bool
  mut finished : Bool
}

///|
pub fn DurableAckPlan::delta(self : DurableAckPlan) -> DurableDelta {
  self.delta
}

///|
fn durable_promoted_actions(
  client_id : @session.ClientId,
  deliveries : Array[@session.SessionDelivery],
) -> Array[BrokerAction] {
  let actions : Array[BrokerAction] = []
  for delivery in deliveries {
    let message = delivery.message.unwrap()
    actions.push(
      Deliver({
        recipient: client_id,
        topic: message.topic,
        payload: copy_router_bytes(message.payload),
        qos: message.qos,
        retain: message.retain,
        packet_id: Some(delivery.packet_id),
        dup: false,
      }),
    )
  }
  actions
}

///|
pub fn BrokerState::prepare_durable_ack(
  self : BrokerState,
  client_id : @session.ClientId,
  packet_id : @session.SessionPacketId,
  kind : DurableAckKind,
  session_generation : Int64,
) -> Result[DurableAckPlan, RouterError] {
  let original = match self.sessions.get(client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(client_id))
  }
  if session_generation < 1L {
    return Err(InvariantViolation("invalid durable session generation"))
  }
  let scratch = match self.reserve_scratch(original.state_bytes() * 3L + 256L) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let candidate = original.copy()
  let before_inflight = original.inflight_count()
  let before_pending = original.pending_count()
  let before_inbound = original.inbound_qos2_count()
  let actions : Array[BrokerAction] = []
  let changed = match kind {
    OutboundPuback | OutboundPubcomp => {
      let ack = candidate.ack(
        packet_id,
        self.session_limits(),
        pubcomp=kind == OutboundPubcomp,
      )
      match ack {
        Err(error) => {
          scratch.release().unwrap()
          return Err(SessionFailure(error))
        }
        Ok(UnknownPacketId) => false
        Ok(Acknowledged(promoted)) => {
          actions.push(DeliveryAcknowledged({ client_id, packet_id }))
          actions.append(durable_promoted_actions(client_id, promoted))
          true
        }
      }
    }
    OutboundPubrec => {
      let advanced = match candidate.pubrec(packet_id) {
        Ok(value) => value
        Err(error) => {
          scratch.release().unwrap()
          return Err(SessionFailure(error))
        }
      }
      actions.push(SendPubrel({ client_id, packet_id }))
      advanced
    }
    InboundPubrel => {
      let deleted = candidate.complete_inbound_qos2(packet_id)
      actions.push(SendPubcomp({ client_id, packet_id }))
      deleted
    }
  }
  let owner = self.resources.owners.get(client_id).unwrap()
  let usage : ResourceUsage = {
    inflight: candidate.inflight_bytes(),
    pending: candidate.pending_bytes(),
    inbound: candidate.inbound_qos2_count().to_int64() * 64L,
    metadata: owner.usage.metadata,
    subscriptions: owner.usage.subscriptions,
  }
  let replacement = if changed && usage != owner.usage {
    match
      self.resources.ledger.prepare_deferred_replacement([
        (owner.ticket, owner.allocations(usage)),
      ]) {
      Ok(value) => Some(value)
      Err(error) => {
        scratch.release().unwrap()
        return Err(ByteResourceLimit(error))
      }
    }
  } else {
    None
  }
  let delta = if changed && original.mode() == @session.SessionMode::Persistent {
    DurableDelta::{
      session_puts: [
        {
          expected_generation: session_generation,
          generation: session_generation,
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
  Ok({
    broker: self,
    client_id,
    candidate,
    before_inflight,
    before_pending,
    before_inbound,
    inflight_bytes: usage.inflight,
    pending_bytes: usage.pending,
    inbound_bytes: usage.inbound,
    metadata_bytes: usage.metadata,
    subscription_bytes: usage.subscriptions,
    replacement,
    scratch,
    actions,
    delta,
    changed,
    finished: false,
  })
}

///|
pub fn DurableAckPlan::commit(
  self : DurableAckPlan,
) -> Result[Array[BrokerAction], RouterError] {
  if self.finished {
    return Err(InvariantViolation("durable ACK plan already finished"))
  }
  if self.replacement is Some(value) {
    match value.commit() {
      Ok(_) => ()
      Err(_) => return Err(InvariantViolation("durable ACK owner changed"))
    }
  }
  if self.changed {
    self.broker.sessions.set(self.client_id, self.candidate)
    self.broker.inflight_total += self.candidate.inflight_count() -
      self.before_inflight
    self.broker.pending_qos1_total += self.candidate.pending_count() -
      self.before_pending
    self.broker.inbound_qos2_total += self.candidate.inbound_qos2_count() -
      self.before_inbound
    self.broker.resources.owners.get(self.client_id).unwrap().usage = {
      inflight: self.inflight_bytes,
      pending: self.pending_bytes,
      inbound: self.inbound_bytes,
      metadata: self.metadata_bytes,
      subscriptions: self.subscription_bytes,
    }
    if self.candidate.mode() == @session.SessionMode::Persistent {
      self.broker.mark_snapshot_dirty()
    }
  }
  self.finished = true
  self.broker.retain_action_lease(self.scratch)
  Ok(self.actions)
}

///|
pub fn DurableAckPlan::cancel(self : DurableAckPlan) -> Unit {
  if !self.finished {
    if self.replacement is Some(value) {
      value.rollback().unwrap()
    }
    self.scratch.release().unwrap()
    self.finished = true
  }
}
