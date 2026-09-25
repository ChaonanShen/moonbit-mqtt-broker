///|
pub struct DurableSubscribePlan {
  broker : BrokerState
  client_id : @session.ClientId
  candidate : @session.ClientSession
  accepted : Array[SubscribeEntry]
  accepted_v5 : Array[SubscribeEntryV5]
  delivery_floor_before : Int64
  subscription_bytes : Int64
  before_revision : Int64
  inflight_added : Int
  pending_added : Int
  state_changed : Bool
  replacement : @budget.Replacement?
  prepare_scratch : @budget.Ticket
  delivery_scratch : @budget.Ticket
  actions : Array[BrokerAction]
  delta : DurableDelta
  mut finished : Bool
}

///|
pub fn DurableSubscribePlan::delta(self : DurableSubscribePlan) -> DurableDelta {
  self.delta
}

///|
pub fn BrokerState::prepare_durable_subscribe(
  self : BrokerState,
  client_id : @session.ClientId,
  entries : Array[SubscribeEntry],
  session_generation : Int64,
  v5_entries? : Array[SubscribeEntryV5] = [],
) -> Result[DurableSubscribePlan, RouterError] {
  let original = match self.sessions.get(client_id) {
    Some(value) if value.is_attached() => value
    _ => return Err(SessionNotFound(client_id))
  }
  if entries.is_empty() ||
    session_generation < 1L ||
    (!v5_entries.is_empty() && v5_entries.length() != entries.length()) {
    return Err(EmptySubscriptionRequest)
  }
  let scratch_bytes = self.retained.count().to_int64() * 192L +
    entries.length().to_int64() * 192L +
    original.state_bytes() * 2L
  let prepare_scratch = match self.reserve_scratch(scratch_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut transferred = false
  defer (if !transferred { prepare_scratch.release().unwrap() })
  let owner = self.resources.owners.get(client_id).unwrap()
  let planned_filters : Map[@topic.TopicFilter, @session.DeliveryQoS] = Map([])
  for record in self.subscriptions.records_for(client_id) {
    planned_filters.set(record.filter, record.qos)
  }
  let accepted : Array[SubscribeEntry] = []
  let accepted_v5 : Array[SubscribeEntryV5] = []
  let planned_bindings : Map[@topic.TopicFilter, SubscriptionBinding] = Map([])
  for binding in self.subscriptions.bindings_for(client_id) {
    planned_bindings.set(binding.filter, binding)
  }
  let results : Array[SubscribeResult] = []
  let successful : Array[@topic.TopicFilter] = []
  let mut added_count = 0
  let mut subscription_bytes = owner.usage.subscriptions
  let mut subscriptions_changed = false
  for index in 0..<entries.length() {
    let entry = entries[index]
    let old = planned_filters.get(entry.filter)
    if old is None &&
      planned_filters.length() >= self.config.max_subscriptions_per_session() {
      results.push(RejectedLimit(SubscriptionsPerSession))
      continue
    }
    if old is None &&
      self.subscriptions.subscription_count() + added_count >=
      self.config.max_subscriptions_total() {
      results.push(RejectedLimit(SubscriptionsTotal))
      continue
    }
    if old is None {
      let next_bytes = subscription_bytes +
        @budget.subscription_cost(entry.filter.value())
      let tentative : ResourceUsage = {
        ..owner.usage,
        subscriptions: next_bytes,
      }
      match
        self.resources.ledger.prepare_deferred_replacement([
          (owner.ticket, owner.allocations(tentative)),
        ]) {
        Ok(check) => check.rollback().unwrap()
        Err(_) => {
          results.push(RejectedLimit(Bytes))
          continue
        }
      }
      subscription_bytes = next_bytes
      added_count += 1
    }
    let v5_entry = if v5_entries.is_empty() {
      None
    } else {
      Some(v5_entries[index])
    }
    if old != Some(entry.qos) {
      subscriptions_changed = true
    }
    if v5_entry is Some(value) {
      let prior = planned_bindings.get(entry.filter)
      let binding : SubscriptionBinding = {
        identity: prior.map(old => old.identity).unwrap_or(0L),
        filter: entry.filter,
        qos: entry.qos,
        no_local: value.no_local,
        retain_as_published: value.retain_as_published,
        retain_handling: value.retain_handling,
        subscription_identifier: value.subscription_identifier,
      }
      if prior != Some(binding) {
        subscriptions_changed = true
      }
      planned_bindings.set(entry.filter, binding)
      accepted_v5.push(value)
      if value.retain_handling == 0 ||
        (value.retain_handling == 1 && old is None) {
        successful.push(entry.filter)
      }
    } else {
      successful.push(entry.filter)
    }
    planned_filters.set(entry.filter, entry.qos)
    accepted.push(entry)
    results.push(Granted(entry.qos))
  }
  let delivery_floor_before = self.next_delivery_id
  let candidates : Array[DeliveryCandidate] = []
  for message in self.retained.matching_for_router(successful) {
    if v5_entries.is_empty() {
      let mut effective : @session.DeliveryQoS? = None
      for filter, qos in planned_filters {
        if filter.matches(message.topic) {
          effective = Some(
            match effective {
              Some(previous) => @session.max_qos(previous, qos)
              None => qos
            },
          )
        }
      }
      if effective is Some(qos) {
        candidates.push({
          recipient: client_id,
          topic: message.topic,
          payload: message.payload,
          qos: @session.min_qos(message.qos, qos),
          retain: true,
          metadata: message.metadata.copy(),
          subscription_identifiers: [],
        })
      }
    } else {
      let mut effective : @session.DeliveryQoS? = None
      let ids : Array[Int] = []
      for _, binding in planned_bindings {
        if !binding.filter.matches(message.topic) ||
          (
            binding.no_local &&
            message.metadata.publisher_client_id == Some(client_id)
          ) {
          continue
        }
        effective = Some(
          match effective {
            Some(previous) => @session.max_qos(previous, binding.qos)
            None => binding.qos
          },
        )
        if binding.subscription_identifier is Some(value) {
          ids.push(value)
        }
      }
      if effective is Some(qos) {
        candidates.push({
          recipient: client_id,
          topic: message.topic,
          payload: message.payload,
          qos: @session.min_qos(message.qos, qos),
          retain: true,
          metadata: message.metadata.copy(),
          subscription_identifiers: ids,
        })
      }
    }
  }
  let planned = match
    self.preflight_deliveries(
      candidates,
      true,
      retained_delta=subscription_bytes - owner.usage.subscriptions,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let prepared = match self.prepare_deliveries(planned, deferred=true) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let candidate = prepared.updates
    .get(client_id)
    .unwrap_or_else(() => original.copy())
  let usage : ResourceUsage = {
    inflight: candidate.inflight_bytes(),
    pending: candidate.pending_bytes(),
    inbound: candidate.inbound_qos2_count().to_int64() * 64L,
    metadata: owner.usage.metadata,
    subscriptions: subscription_bytes,
  }
  let replacement = if usage != owner.usage {
    match
      self.resources.ledger.prepare_deferred_replacement([
        (owner.ticket, owner.allocations(usage)),
      ]) {
      Ok(value) => Some(value)
      Err(error) => {
        prepared.scratch.release().unwrap()
        return Err(ByteResourceLimit(error))
      }
    }
  } else {
    None
  }
  let subscriptions : Array[SnapshotSubscriptionV3] = []
  for filter, qos in planned_filters {
    subscriptions.push({ filter: filter.value(), qos: snapshot_qos(qos) })
  }
  subscriptions.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.filter, right.filter)
  })
  let delivery_changed = prepared.inflight_added > 0 ||
    prepared.pending_added > 0
  let state_changed = subscriptions_changed ||
    delivery_changed ||
    !accepted.is_empty()
  if !accepted.is_empty() {
    candidate.subscription_changed()
  }
  let delta = if original.mode() == @session.Persistent && state_changed {
    DurableDelta::{
      session_puts: [
        {
          expected_generation: session_generation,
          generation: session_generation,
          session: self.snapshot_session_candidate(
            client_id,
            candidate,
            planned_subscriptions=subscriptions,
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
  let actions : Array[BrokerAction] = [
    SubscriptionsApplied({ client_id, results }),
  ]
  actions.append(prepared.actions)
  transferred = true
  Ok({
    broker: self,
    client_id,
    candidate,
    accepted,
    accepted_v5,
    delivery_floor_before,
    subscription_bytes,
    before_revision: self.snapshot_revision(),
    inflight_added: prepared.inflight_added,
    pending_added: prepared.pending_added,
    state_changed,
    replacement,
    prepare_scratch,
    delivery_scratch: prepared.scratch,
    actions,
    delta,
    finished: false,
  })
}

///|
pub fn DurableSubscribePlan::commit(
  self : DurableSubscribePlan,
) -> Result[Array[BrokerAction], RouterError] {
  if self.finished || self.broker.snapshot_revision() != self.before_revision {
    return Err(InvariantViolation("durable subscribe state changed"))
  }
  if self.replacement is Some(value) {
    match value.commit() {
      Ok(_) => ()
      Err(_) =>
        return Err(InvariantViolation("durable subscribe owner changed"))
    }
  }
  for index in 0..<self.accepted.length() {
    let entry = self.accepted[index]
    let old = self.broker.subscriptions.qos(self.client_id, entry.filter)
    if self.accepted_v5.is_empty() {
      ignore(
        self.broker.subscriptions.put(self.client_id, entry.filter, entry.qos),
      )
    } else {
      let options = self.accepted_v5[index]
      ignore(
        self.broker.subscriptions.put_v5(
          self.client_id,
          entry.filter,
          entry.qos,
          options.no_local,
          options.retain_as_published,
          options.retain_handling,
          options.subscription_identifier,
        ),
      )
    }
    if old is None && self.broker.admin_sessions is Some(index) {
      index.register_subscription(self.client_id, entry.filter)
    }
  }
  self.broker.sessions.set(self.client_id, self.candidate)
  let owner = self.broker.resources.owners.get(self.client_id).unwrap()
  owner.usage = {
    inflight: self.candidate.inflight_bytes(),
    pending: self.candidate.pending_bytes(),
    inbound: self.candidate.inbound_qos2_count().to_int64() * 64L,
    metadata: owner.usage.metadata,
    subscriptions: self.subscription_bytes,
  }
  self.broker.inflight_total += self.inflight_added
  self.broker.pending_qos1_total += self.pending_added
  if self.state_changed && self.candidate.mode() == @session.Persistent {
    self.broker.mark_snapshot_dirty()
  }
  self.finished = true
  self.broker.retain_action_lease(self.prepare_scratch)
  self.broker.retain_action_lease(self.delivery_scratch)
  Ok(self.actions)
}

///|
pub fn DurableSubscribePlan::cancel(self : DurableSubscribePlan) -> Unit {
  if !self.finished {
    if self.replacement is Some(value) {
      value.rollback().unwrap()
    }
    self.prepare_scratch.release().unwrap()
    self.delivery_scratch.release().unwrap()
    self.finished = true
  }
}

///|
pub fn DurableSubscribePlan::delta_v5(
  self : DurableSubscribePlan,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[DurableDeltaV5, RouterError] {
  let id_floors : Array[Mqtt5IdFloor] = []
  let planned : Map[@topic.TopicFilter, SubscriptionBinding] = Map([])
  for binding in self.broker.subscriptions.bindings_for(self.client_id) {
    planned.set(binding.filter, binding)
  }
  let mut next_identity = self.broker.subscriptions.next_identity()
  for index in 0..<self.accepted.length() {
    let entry = self.accepted[index]
    if next_identity == 9223372036854775807L {
      return Err(InvariantViolation("subscription identity exhausted"))
    }
    let options = if self.accepted_v5.is_empty() {
      None
    } else {
      Some(self.accepted_v5[index])
    }
    planned.set(entry.filter, {
      identity: next_identity,
      filter: entry.filter,
      qos: entry.qos,
      no_local: options.map(value => value.no_local).unwrap_or(false),
      retain_as_published: options
      .map(value => value.retain_as_published)
      .unwrap_or(false),
      retain_handling: options.map(value => value.retain_handling).unwrap_or(0),
      subscription_identifier: match options {
        Some(value) => value.subscription_identifier
        None => None
      },
    })
    next_identity += 1L
  }
  if next_identity > self.broker.subscriptions.next_identity() {
    id_floors.push({ kind: 2, new_floor: next_identity })
  }
  if self.broker.next_delivery_id > self.delivery_floor_before {
    id_floors.push({ kind: 3, new_floor: self.broker.next_delivery_id })
  }
  let bindings : Array[SubscriptionBinding] = []
  for _, binding in planned {
    bindings.push(binding)
  }
  bindings.sort_by(fn(left, right) {
    if left.identity < right.identity {
      -1
    } else if left.identity > right.identity {
      1
    } else {
      0
    }
  })
  let session_puts : Array[Mqtt5SessionPut] = []
  if self.state_changed && self.candidate.mode() == @session.Persistent {
    let put = match
      self.broker.session_put_v5(
        self.client_id,
        self.candidate,
        now_mono_ms,
        now_wall_ms,
        bindings~,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    session_puts.push(put)
  }
  Ok({
    ..DurableDeltaV5::empty(),
    new_clock_floor: if now_wall_ms > self.broker.clock_floor_wall_ms {
      Some(now_wall_ms)
    } else {
      None
    },
    id_floors,
    session_puts,
  })
}
