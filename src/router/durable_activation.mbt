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
  proposed_incarnation : Int64?
  cancel_wills : Array[Int64]
  trigger_wills : Array[(Int64, @session.Retention)]
  mut will_transition_mono_ms : Int64
  mut will_transition_wall_ms : Int64
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
pub fn DurableActivationPlan::persistent_after(
  self : DurableActivationPlan,
) -> Bool {
  self.candidate.mode() == @session.Persistent
}

///|
pub fn DurableActivationPlan::session_incarnation_after(
  self : DurableActivationPlan,
) -> Int64 {
  self.proposed_incarnation.unwrap_or_else(() => {
    self.broker.session_incarnation(self.client_id).unwrap()
  })
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
  v5_resume? : Bool = false,
  v5_retention? : @session.Retention,
  now_mono_ms? : Int64 = 0L,
  v5_peer_receive_maximum? : Int = 65535,
) -> Result[DurableActivationPlan, RouterError] {
  let old = self.sessions.get(id)
  if old is None && self.sessions.length() >= self.config.max_sessions() {
    return Err(SessionLimitReached(self.config.max_sessions()))
  }
  let restoring = if v5_retention is Some(_) {
    v5_resume && old is Some(value) && !value.logically_expired(now_mono_ms)
  } else {
    mode == @session.Persistent &&
    old is Some(value) &&
    value.mode() == @session.Persistent
  }
  let old_persistent = old is Some(value) && value.mode() == @session.Persistent
  let cancel_wills : Array[Int64] = []
  let trigger_wills : Array[(Int64, @session.Retention)] = []
  if old is Some(previous) && self.session_incarnation(id) is Some(incarnation) {
    for will_id, record in self.wills {
      if record.client_id == id && record.session_incarnation == incarnation {
        if restoring {
          if record.state == WillPending {
            if record.due is Some(due) && due.remaining_at(now_mono_ms) > 0L {
              cancel_wills.push(will_id)
            }
          } else {
            let effective_delay = match previous.retention() {
              @session.DropOnClose => 0U
              @session.FiniteV5(expiry) if expiry <
                record.template.delay_seconds => expiry
              _ => record.template.delay_seconds
            }
            if effective_delay == 0U {
              trigger_wills.push((will_id, previous.retention()))
            } else {
              cancel_wills.push(will_id)
            }
          }
        } else if record.state == WillArmed {
          trigger_wills.push((will_id, previous.retention()))
        }
      }
    }
  }
  let proposed_incarnation = if restoring {
    None
  } else {
    if self.next_session_incarnation == 9223372036854775807L {
      return Err(InvariantViolation("session incarnation exhausted"))
    }
    let reserved = self.next_session_incarnation
    self.next_session_incarnation += 1L
    Some(reserved)
  }
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
    let global_free_slots = self.config.max_inflight_total() -
      self.inflight_total +
      old.unwrap().inflight_count()
    let max_inflight = if global_free_slots <
      self.config.max_inflight_per_session() {
      global_free_slots
    } else {
      self.config.max_inflight_per_session()
    }
    let replay_inflight_limit = if v5_retention is Some(_) &&
      v5_peer_receive_maximum < max_inflight {
      v5_peer_receive_maximum
    } else {
      max_inflight
    }
    let deliveries = match
      candidate.attach(
        self.session_limits(max_inflight=replay_inflight_limit),
        pubrel_first=v5_retention is Some(_),
      ) {
      Ok(value) => value
      Err(error) => {
        scratch.release().unwrap()
        return Err(SessionFailure(error))
      }
    }
    (
      if v5_retention is Some(retention) {
        candidate.with_retention(retention)
      } else {
        candidate
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
  let desired : ResourceUsage = if restoring {
    {
      ..desired,
      inflight: candidate.inflight_bytes(),
      pending: candidate.pending_bytes(),
      inbound: candidate.inbound_qos2_count().to_int64() * 64L,
    }
  } else {
    desired
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
              dup: delivery.dup,
            },
            message.metadata,
            message.subscription_identifiers,
          ),
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
    proposed_incarnation,
    cancel_wills,
    trigger_wills,
    will_transition_mono_ms: 0L,
    will_transition_wall_ms: 0L,
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
  self.broker.track_policy_session(self.client_id)
  if self.proposed_incarnation is Some(value) {
    self.broker.session_incarnations.set(self.client_id, value)
  }
  if old is Some(_) && self.reset {
    self.broker.replace_policy_session(self.client_id)
  }
  self.broker.sessions.set(self.client_id, self.candidate)
  ignore(self.broker.session_expiry.remove(self.client_id.value()))
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
  for will_id in self.cancel_wills {
    if !self.broker.cancel_will(will_id) {
      return Err(InvariantViolation("resumed Will cancellation failed"))
    }
  }
  for entry in self.trigger_wills {
    let (will_id, retention) = entry
    if !self.broker.trigger_will(
        will_id,
        self.will_transition_mono_ms,
        self.will_transition_wall_ms,
        retention,
      ) {
      return Err(InvariantViolation("replaced Will transition failed"))
    }
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

///|
pub fn DurableActivationPlan::delta_v5(
  self : DurableActivationPlan,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[DurableDeltaV5, RouterError] {
  let session_puts : Array[Mqtt5SessionPut] = []
  let session_deletes : Array[Mqtt5SessionDelete] = []
  let old = self.broker.sessions.get(self.client_id)
  let old_persistent = old is Some(value) && value.mode() == @session.Persistent
  if self.candidate.mode() == @session.Persistent {
    let incarnation = self.proposed_incarnation.unwrap_or_else(() => {
      self.broker.session_incarnation(self.client_id).unwrap()
    })
    let put = match
      self.broker.session_put_v5(
        self.client_id,
        self.candidate,
        now_mono_ms,
        now_wall_ms,
        proposed_incarnation=incarnation,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    session_puts.push({
      ..put,
      expected_incarnation: if old_persistent {
        self.broker.session_incarnation(self.client_id).unwrap()
      } else {
        0L
      },
      expected_revision: if old_persistent {
        old.unwrap().policy_revision()
      } else {
        0L
      },
    })
  } else if old_persistent {
    session_deletes.push({
      client_id: self.client_id.value(),
      expected_incarnation: self.broker
      .session_incarnation(self.client_id)
      .unwrap(),
      expected_revision: old.unwrap().policy_revision(),
    })
  }
  let id_floors : Array[Mqtt5IdFloor] = []
  if self.proposed_incarnation is Some(_) {
    id_floors.push({ kind: 1, new_floor: self.broker.next_session_incarnation })
  }
  let will_deletes : Array[Mqtt5WillDelete] = []
  for id in self.cancel_wills {
    let record = match self.broker.wills.get(id) {
      Some(value) => value
      None =>
        return Err(InvariantViolation("Will disappeared before activation"))
    }
    if old_persistent {
      will_deletes.push({ id, expected_revision: record.revision })
    }
  }
  let will_puts : Array[Mqtt5WillPut] = []
  for entry in self.trigger_wills {
    let (id, retention) = entry
    let record = match self.broker.wills.get(id) {
      Some(value) if value.state == WillArmed => value
      _ => return Err(InvariantViolation("old Will disappeared"))
    }
    let delay = match retention {
      @session.DropOnClose => 0U
      @session.FiniteV5(expiry) if expiry < record.template.delay_seconds =>
        expiry
      _ => record.template.delay_seconds
    }
    let due = match
      @session.Deadline::from_seconds(now_mono_ms, now_wall_ms, delay) {
      Ok(value) => value
      Err(_) => return Err(InvariantViolation("Will transition clock overflow"))
    }
    let next = {
      ..record,
      state: WillPending,
      trigger_wall_ms: Some(now_wall_ms),
      due: Some(due),
      revision: record.revision + 1L,
    }
    let saved = match durable_will_snapshot(next, now_mono_ms, now_wall_ms) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    will_puts.push({
      expected_revision: if old_persistent {
        record.revision
      } else {
        0L
      },
      will: saved,
    })
  }
  self.will_transition_mono_ms = now_mono_ms
  self.will_transition_wall_ms = now_wall_ms
  Ok({
    ..DurableDeltaV5::empty(),
    will_puts,
    will_deletes,
    new_clock_floor: if now_wall_ms > self.broker.clock_floor_wall_ms {
      Some(now_wall_ms)
    } else {
      None
    },
    id_floors,
    session_puts,
    session_deletes,
  })
}
