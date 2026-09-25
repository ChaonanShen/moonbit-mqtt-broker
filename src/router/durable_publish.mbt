///|
pub struct DurablePublishPlan {
  broker : BrokerState
  input : PublishInput
  metadata : @session.MessageMetadata
  delivery_floor_before : Int64
  updates : Map[@session.ClientId, @session.ClientSession]
  inflight_added : Int
  pending_added : Int
  inbound_added : Int
  retained_target_bytes : Int64
  retained_changed : Bool
  delivery_changed : Bool
  replacement : @budget.Replacement?
  prepare_scratch : @budget.Ticket
  delivery_scratch : @budget.Ticket
  actions : Array[BrokerAction]
  delta : DurableDelta
  mut finished : Bool
}

///|
pub fn DurablePublishPlan::delta(self : DurablePublishPlan) -> DurableDelta {
  self.delta
}

///|
pub fn BrokerState::prepare_durable_publish(
  self : BrokerState,
  source : PublishInput,
  generations : Map[@session.ClientId, Int64],
  inbound_packet_id? : @session.SessionPacketId,
  metadata? : @session.MessageMetadata = @session.MessageMetadata::empty(),
) -> Result[DurablePublishPlan, RouterError] {
  if source.retain &&
    source.payload.length() > 0 &&
    self.retained.peek(source.topic) is None &&
    self.retained.count() >= self.config.max_retained_messages() {
    return Err(RetainedLimitReached(self.config.max_retained_messages()))
  }
  let inbound_client : @session.ClientId? = match inbound_packet_id {
    None => None
    Some(packet_id) => {
      let client_id = match source.origin {
        Client(value) if source.qos == @session.DeliveryQoS::QoS2 => value
        _ =>
          return Err(
            InvariantViolation("invalid durable inbound QoS 2 publication"),
          )
      }
      let session = match self.sessions.get(client_id) {
        Some(value) if value.is_attached() => value
        _ => return Err(InvalidSessionState(client_id))
      }
      if session.has_inbound_qos2(packet_id) {
        return Err(
          InvariantViolation("duplicate inbound QoS 2 must use committed reply"),
        )
      }
      if session.inbound_qos2_count() >=
        self.config.max_inbound_qos2_per_session() {
        return Err(InboundQoS2ResourceLimit(InboundQoS2PerSession))
      }
      if self.inbound_qos2_total >= self.config.max_inbound_qos2_total() {
        return Err(InboundQoS2ResourceLimit(InboundQoS2Total))
      }
      Some(client_id)
    }
  }
  let new_retained_cost = if source.retain && source.payload.length() > 0 {
    @budget.message_cost(
      source.topic.value(),
      source.payload.length().to_int64(),
    ).unwrap()
  } else {
    0L
  }
  if new_retained_cost > 0L &&
    new_retained_cost - 96L >
    self.config.resources.get("max_retained_message_bytes") {
    return Err(ByteResourceLimit(@budget.BudgetError::InvalidAmount))
  }
  let descriptor_bytes = self.subscriptions.subscription_count().to_int64() *
    192L
  let prepare_scratch = match
    self.reserve_scratch(descriptor_bytes + new_retained_cost * 2L) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut transferred = false
  defer (if !transferred { prepare_scratch.release().unwrap() })
  let input : PublishInput = {
    ..source,
    payload: copy_router_bytes(source.payload),
  }
  let delivery_floor_before = self.next_delivery_id
  let old_retained = self.retained.peek(input.topic)
  let old_retained_cost = self.retained.cost_at(input.topic)
  let retained_target_bytes = self.resources.retained_bytes -
    old_retained_cost +
    new_retained_cost
  let retained_delta = if input.retain {
    new_retained_cost - old_retained_cost
  } else {
    0L
  }
  let strict = input.origin is Client(_)
  let planned = match
    self.preflight_deliveries(
      self.delivery_candidates(input, metadata~),
      strict,
      retained_delta~,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let delivery_changed = self.planned_changes_snapshot(planned)
  let prepared = match self.prepare_deliveries(planned, deferred=true) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut inbound_added = 0
  if inbound_client is Some(client_id) && inbound_packet_id is Some(packet_id) {
    let candidate = match prepared.updates.get(client_id) {
      Some(value) => value
      None => self.sessions.get(client_id).unwrap().copy()
    }
    match candidate.begin_inbound_qos2(packet_id, self.session_limits()) {
      Ok(true) => inbound_added = 1
      Ok(false) | Err(_) => {
        prepared.scratch.release().unwrap()
        return Err(InboundQoS2ResourceLimit(Bytes))
      }
    }
    prepared.updates.set(client_id, candidate)
    let usage = prepared.usage_updates
      .get(client_id)
      .unwrap_or(self.resources.owners.get(client_id).unwrap().usage)
    prepared.usage_updates.set(client_id, {
      ..usage,
      inbound: usage.inbound + 64L,
    })
  }
  let session_puts : Array[DurableSessionPut] = []
  for id, candidate in prepared.updates {
    if candidate.mode() == @session.SessionMode::Persistent {
      let generation = match generations.get(id) {
        Some(value) if value > 0L => value
        _ => {
          prepared.scratch.release().unwrap()
          return Err(
            InvariantViolation("persistent session missing generation"),
          )
        }
      }
      session_puts.push({
        expected_generation: generation,
        generation,
        session: self.snapshot_session_candidate(id, candidate),
      })
    }
  }
  session_puts.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.session.client_id, right.session.client_id)
  })
  let retained_changed = if !input.retain {
    false
  } else if input.payload.length() == 0 {
    old_retained is Some(_)
  } else {
    old_retained !=
    Some({
      topic: input.topic,
      payload: input.payload,
      qos: input.qos,
      metadata,
    })
  }
  let retained_puts : Array[SnapshotRetainedV3] = []
  let retained_deletes : Array[String] = []
  if retained_changed {
    if input.payload.length() == 0 {
      retained_deletes.push(input.topic.value())
    } else {
      retained_puts.push({
        topic: input.topic.value(),
        payload: copy_router_bytes(input.payload),
        qos: snapshot_qos(input.qos),
      })
    }
  }
  let requests : Array[(@budget.Ticket, Array[@budget.Allocation])] = []
  if input.retain {
    requests.push(
      (
        self.resources.retained_ticket,
        [self.resources.retained_pool.allocation(retained_target_bytes)],
      ),
    )
  }
  for id, usage in prepared.usage_updates {
    let owner = self.resources.owners.get(id).unwrap()
    requests.push((owner.ticket, owner.allocations(usage)))
  }
  let replacement = if requests.is_empty() {
    None
  } else {
    match self.resources.ledger.prepare_deferred_replacement(requests) {
      Ok(value) => Some(value)
      Err(error) => {
        prepared.scratch.release().unwrap()
        return Err(ByteResourceLimit(error))
      }
    }
  }
  let delta = {
    session_puts,
    session_deletes: [],
    retained_puts,
    retained_deletes,
  }
  let actions : Array[BrokerAction] = []
  if inbound_client is Some(client_id) && inbound_packet_id is Some(packet_id) {
    actions.push(SendPubrec({ client_id, packet_id }))
  }
  actions.append(prepared.actions)
  transferred = true
  Ok({
    broker: self,
    input,
    metadata: metadata.copy(),
    delivery_floor_before,
    updates: prepared.updates,
    inflight_added: prepared.inflight_added,
    pending_added: prepared.pending_added,
    inbound_added,
    retained_target_bytes,
    retained_changed,
    delivery_changed,
    replacement,
    prepare_scratch,
    delivery_scratch: prepared.scratch,
    actions,
    delta,
    finished: false,
  })
}

///|
pub fn DurablePublishPlan::commit(
  self : DurablePublishPlan,
) -> Result[Array[BrokerAction], RouterError] {
  if self.finished {
    return Err(InvariantViolation("durable publish plan already finished"))
  }
  if self.replacement is Some(value) {
    match value.commit() {
      Ok(_) => ()
      Err(_) => return Err(InvariantViolation("durable publish owner changed"))
    }
  }
  if self.input.retain {
    self.broker.resources.retained_bytes = self.retained_target_bytes
    let previous = self.broker.retained.peek(self.input.topic)
    if self.input.payload.length() == 0 {
      self.broker.retained.remove(self.input.topic)
      if previous is Some(_) && self.broker.admin_sessions is Some(index) {
        index.remove_retained(self.input.topic)
      }
    } else {
      ignore(
        self.broker.retained.put(
          self.input.topic,
          self.input.payload,
          self.input.qos,
          self.broker.config.max_retained_messages(),
          metadata=self.metadata,
        ),
      )
      if previous is None && self.broker.admin_sessions is Some(index) {
        index.register_retained(self.input.topic)
      }
    }
  }
  for id, session in self.updates {
    let owner = self.broker.resources.owners.get(id).unwrap()
    owner.usage = {
      inflight: session.inflight_bytes(),
      pending: session.pending_bytes(),
      inbound: session.inbound_qos2_count().to_int64() * 64L,
      metadata: owner.usage.metadata,
      subscriptions: owner.usage.subscriptions,
    }
    self.broker.sessions.set(id, session)
  }
  self.broker.inflight_total += self.inflight_added
  self.broker.pending_qos1_total += self.pending_added
  self.broker.inbound_qos2_total += self.inbound_added
  if self.retained_changed || self.delivery_changed || self.inbound_added > 0 {
    self.broker.mark_snapshot_dirty()
  }
  self.finished = true
  self.broker.retain_action_lease(self.prepare_scratch)
  self.broker.retain_action_lease(self.delivery_scratch)
  Ok(self.actions)
}

///|
pub fn DurablePublishPlan::cancel(self : DurablePublishPlan) -> Unit {
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
pub fn DurablePublishPlan::delta_v5(
  self : DurablePublishPlan,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[DurableDeltaV5, RouterError] {
  let session_puts : Array[Mqtt5SessionPut] = []
  for id, candidate in self.updates {
    if candidate.mode() != @session.Persistent {
      continue
    }
    match self.broker.session_put_v5(id, candidate, now_mono_ms, now_wall_ms) {
      Ok(value) => session_puts.push(value)
      Err(error) => return Err(error)
    }
  }
  session_puts.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.session.client_id, right.session.client_id)
  })
  let id_floors : Array[Mqtt5IdFloor] = []
  if self.broker.next_delivery_id > self.delivery_floor_before {
    id_floors.push({ kind: 3, new_floor: self.broker.next_delivery_id })
  }
  let retained_puts : Array[Mqtt5RetainedPut] = []
  let retained_deletes : Array[Mqtt5RetainedDelete] = []
  if self.retained_changed {
    let expected = self.broker.retained.revision(self.input.topic).unwrap_or(0L)
    if self.input.payload.length() == 0 {
      retained_deletes.push({
        topic: self.input.topic.value(),
        expected_revision: expected,
      })
    } else {
      let revision = self.broker.retained.next_revision()
      if revision == 9223372036854775807L {
        return Err(InvariantViolation("retained revision exhausted"))
      }
      id_floors.push({ kind: 6, new_floor: revision + 1L })
      let message = @session.SessionMessage::new(
        self.input.topic,
        self.input.payload,
        true,
        qos=self.input.qos,
        metadata=self.metadata,
      )
      let saved = match v5_snapshot_message(message, now_mono_ms, now_wall_ms) {
        Ok(value) => value
        Err(_) =>
          return Err(InvariantViolation("cannot encode V5 retained message"))
      }
      retained_puts.push({
        expected_revision: expected,
        retained: { revision, message: saved },
      })
    }
  }
  Ok({
    new_clock_floor: if now_wall_ms > self.broker.clock_floor_wall_ms {
      Some(now_wall_ms)
    } else {
      None
    },
    id_floors,
    session_puts,
    session_deletes: [],
    group_puts: [],
    group_deletes: [],
    retained_puts,
    retained_deletes,
    will_puts: [],
    will_deletes: [],
  })
}
