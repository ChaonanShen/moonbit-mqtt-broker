///|
pub struct DurableUnsubscribePlan {
  broker : BrokerState
  client_id : @session.ClientId
  remove_filters : Array[@topic.TopicFilter]
  subscription_bytes : Int64
  before_revision : Int64
  replacement : @budget.Replacement?
  scratch : @budget.Ticket
  action : BrokerAction
  delta : DurableDelta
  mut finished : Bool
}

///|
pub fn DurableUnsubscribePlan::delta(
  self : DurableUnsubscribePlan,
) -> DurableDelta {
  self.delta
}

///|
pub fn BrokerState::prepare_durable_unsubscribe(
  self : BrokerState,
  client_id : @session.ClientId,
  filters : Array[@topic.TopicFilter],
  session_generation : Int64,
) -> Result[DurableUnsubscribePlan, RouterError] {
  let session = match self.sessions.get(client_id) {
    Some(value) if value.is_attached() => value
    _ => return Err(SessionNotFound(client_id))
  }
  if filters.is_empty() || session_generation < 1L {
    return Err(EmptyUnsubscriptionRequest)
  }
  let scratch = match
    self.reserve_scratch(
      filters.length().to_int64() * 192L + session.state_bytes() * 2L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut transferred = false
  defer (if !transferred { scratch.release().unwrap() })
  let owner = self.resources.owners.get(client_id).unwrap()
  let seen : Map[@topic.TopicFilter, Bool] = Map([])
  let remove_filters : Array[@topic.TopicFilter] = []
  let removed : Array[Bool] = []
  let mut subscription_bytes = owner.usage.subscriptions
  for filter in filters {
    let changed = !seen.contains(filter) &&
      self.subscriptions.qos(client_id, filter) is Some(_)
    seen.set(filter, true)
    removed.push(changed)
    if changed {
      remove_filters.push(filter)
      subscription_bytes -= @budget.subscription_cost(filter.value())
    }
  }
  let replacement = if subscription_bytes != owner.usage.subscriptions {
    let usage : ResourceUsage = {
      ..owner.usage,
      subscriptions: subscription_bytes,
    }
    match
      self.resources.ledger.prepare_deferred_replacement([
        (owner.ticket, owner.allocations(usage)),
      ]) {
      Ok(value) => Some(value)
      Err(error) => return Err(ByteResourceLimit(error))
    }
  } else {
    None
  }
  let planned_subscriptions : Array[SnapshotSubscriptionV3] = []
  for record in self.subscriptions.records_for(client_id) {
    if !seen.contains(record.filter) || !remove_filters.contains(record.filter) {
      planned_subscriptions.push({
        filter: record.filter.value(),
        qos: snapshot_qos(record.qos),
      })
    }
  }
  let delta = if session.mode() == @session.Persistent &&
    !remove_filters.is_empty() {
    DurableDelta::{
      session_puts: [
        {
          expected_generation: session_generation,
          generation: session_generation,
          session: self.snapshot_session_candidate(
            client_id,
            session,
            planned_subscriptions~,
          ),
        },
      ],
      session_deletes: [],
      retained_puts: [],
      retained_deletes: [],
    }
  } else {
    DurableDelta::empty()
  }
  transferred = true
  Ok({
    broker: self,
    client_id,
    remove_filters,
    subscription_bytes,
    before_revision: self.snapshot_revision(),
    replacement,
    scratch,
    action: UnsubscriptionsApplied({ client_id, removed }),
    delta,
    finished: false,
  })
}

///|
pub fn DurableUnsubscribePlan::commit(
  self : DurableUnsubscribePlan,
) -> Result[Array[BrokerAction], RouterError] {
  if self.finished || self.broker.snapshot_revision() != self.before_revision {
    return Err(InvariantViolation("durable unsubscribe state changed"))
  }
  if self.replacement is Some(value) {
    match value.commit() {
      Ok(_) => ()
      Err(_) =>
        return Err(InvariantViolation("durable unsubscribe owner changed"))
    }
  }
  for filter in self.remove_filters {
    ignore(self.broker.subscriptions.remove(self.client_id, filter))
    if self.broker.admin_sessions is Some(index) {
      index.remove_subscription(self.client_id, filter)
    }
  }
  if !self.remove_filters.is_empty() {
    self.broker.sessions.get(self.client_id).unwrap().subscription_changed()
  }
  let owner = self.broker.resources.owners.get(self.client_id).unwrap()
  owner.usage = { ..owner.usage, subscriptions: self.subscription_bytes }
  if !self.remove_filters.is_empty() &&
    self.broker.session_is_persistent(self.client_id) {
    self.broker.mark_snapshot_dirty()
  }
  self.finished = true
  self.scratch.release().unwrap()
  Ok([self.action])
}

///|
pub fn DurableUnsubscribePlan::cancel(self : DurableUnsubscribePlan) -> Unit {
  if !self.finished {
    if self.replacement is Some(value) {
      value.rollback().unwrap()
    }
    self.scratch.release().unwrap()
    self.finished = true
  }
}

///|
pub fn DurableUnsubscribePlan::delta_v5(
  self : DurableUnsubscribePlan,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[DurableDeltaV5, RouterError] {
  let session_puts : Array[Mqtt5SessionPut] = []
  if !self.remove_filters.is_empty() &&
    self.broker.session_is_persistent(self.client_id) {
    let original = self.broker.sessions.get(self.client_id).unwrap()
    let bindings : Array[SubscriptionBinding] = []
    for binding in self.broker.subscriptions.bindings_for(self.client_id) {
      if !self.remove_filters.contains(binding.filter) {
        bindings.push(binding)
      }
    }
    let saved = match
      self.broker.snapshot_session_v5_candidate(
        self.client_id,
        original,
        now_mono_ms,
        now_wall_ms,
        bindings~,
      ) {
      Ok(value) => value
      Err(_) =>
        return Err(InvariantViolation("cannot export V5 unsubscribe Session"))
    }
    session_puts.push({
      expected_incarnation: self.broker
      .session_incarnation(self.client_id)
      .unwrap(),
      expected_revision: original.policy_revision(),
      session: { ..saved, state_revision: original.policy_revision() + 1L },
    })
  }
  Ok({
    ..DurableDeltaV5::empty(),
    new_clock_floor: if now_wall_ms > self.broker.clock_floor_wall_ms {
      Some(now_wall_ms)
    } else {
      None
    },
    session_puts,
  })
}
