///|
pub(all) enum Mqtt5WillState {
  WillArmed
  WillPending
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5WillTemplate {
  topic : @topic.TopicName
  payload : Bytes
  qos : @session.DeliveryQoS
  retain : Bool
  metadata : @session.MessageMetadata
  delay_seconds : UInt
  message_expiry_seconds : UInt?
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5WillRecord {
  id : Int64
  owner : @security.Principal
  client_id : @session.ClientId
  session_incarnation : Int64
  state : Mqtt5WillState
  template : Mqtt5WillTemplate
  trigger_wall_ms : Int64?
  due : @session.Deadline?
  policy_sequence : Int64
  revision : Int64
} derive(Eq, Debug)

///|
pub struct PreparedMqtt5Will {
  record : Mqtt5WillRecord
  ticket : @budget.Ticket
  mut finished : Bool
}

///|
pub fn PreparedMqtt5Will::id(self : PreparedMqtt5Will) -> Int64 {
  self.record.id
}

///|
pub fn PreparedMqtt5Will::delta_v5(
  self : PreparedMqtt5Will,
  incarnation : Int64,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[DurableDeltaV5, RouterError] {
  if self.finished || incarnation < 1L {
    return Err(InvariantViolation("invalid prepared Will"))
  }
  let template = @session.SessionMessage::new(
    self.record.template.topic,
    self.record.template.payload,
    self.record.template.retain,
    qos=self.record.template.qos,
    metadata=self.record.template.metadata,
  )
  let message = match v5_snapshot_message(template, now_mono_ms, now_wall_ms) {
    Ok(value) => value
    Err(_) => return Err(InvariantViolation("cannot snapshot prepared Will"))
  }
  let will : SnapshotWillV5 = {
    id: self.record.id,
    owner_principal: self.record.owner.storage_value(),
    client_id: self.record.client_id.value(),
    session_incarnation: incarnation,
    state: 0,
    message_template: message,
    delay_seconds: self.record.template.delay_seconds,
    will_message_expiry_seconds: self.record.template.message_expiry_seconds,
    trigger_wall_ms: None,
    due_clock: None,
    policy_sequence: self.record.policy_sequence,
    revision: self.record.revision,
  }
  Ok({
    ..DurableDeltaV5::empty(),
    id_floors: [{ kind: 5, new_floor: self.record.id + 1L }],
    will_puts: [{ expected_revision: 0L, will }],
  })
}

///|
pub fn BrokerState::will_count(self : BrokerState) -> Int {
  self.wills.length()
}

///|
pub fn BrokerState::prepare_mqtt5_will(
  self : BrokerState,
  client_id : @session.ClientId,
  owner : @security.Principal,
  template : Mqtt5WillTemplate,
  max_count : Int,
  policy_sequence : Int64,
) -> Result[PreparedMqtt5Will, RouterError] {
  if max_count < 1 || self.wills.length() >= max_count {
    return Err(InvariantViolation("delayed Will capacity reached"))
  }
  if self.next_will_id < 1L || self.next_will_id == 9223372036854775807L {
    return Err(InvariantViolation("Will identity exhausted"))
  }
  let cost = @budget.checked_add(
    @budget.message_cost(
      template.topic.value(),
      template.payload.length().to_int64(),
    ).unwrap(),
    template.metadata.cost() + 256L,
  ).unwrap()
  let limits = self.config.resources()
  let pool = self.resources.ledger
    .pool(Will, limits.get("max_will_bytes_total"))
    .unwrap()
  let ticket = match pool.reserve(cost) {
    Ok(value) => value
    Err(error) => return Err(ByteResourceLimit(error))
  }
  let id = self.next_will_id
  self.next_will_id += 1L
  Ok({
    record: {
      id,
      owner,
      client_id,
      session_incarnation: 0L,
      state: WillArmed,
      template,
      trigger_wall_ms: None,
      due: None,
      policy_sequence,
      revision: 1L,
    },
    ticket,
    finished: false,
  })
}

///|
pub fn BrokerState::cancel_prepared_will(
  self : BrokerState,
  prepared : PreparedMqtt5Will,
) -> Unit {
  ignore(self)
  if !prepared.finished {
    prepared.finished = true
    prepared.ticket.release().unwrap()
  }
}

///|
pub fn BrokerState::commit_prepared_will(
  self : BrokerState,
  prepared : PreparedMqtt5Will,
) -> Int64 {
  if prepared.finished {
    abort("Will prepared record already finalized")
  }
  prepared.finished = true
  prepared.ticket.commit().unwrap()
  let id = prepared.record.id
  let incarnation = self.session_incarnation(prepared.record.client_id).unwrap()
  self.wills.set(id, { ..prepared.record, session_incarnation: incarnation })
  self.will_tickets.set(id, prepared.ticket)
  self.active_will_by_client.set(prepared.record.client_id, id)
  self.mark_snapshot_dirty()
  id
}

///|
pub fn BrokerState::cancel_will(self : BrokerState, id : Int64) -> Bool {
  let record = match self.wills.get(id) {
    Some(value) => value
    None => return false
  }
  self.wills.remove(id)
  if self.active_will_by_client.get(record.client_id) == Some(id) {
    self.active_will_by_client.remove(record.client_id)
  }
  if self.will_tickets.get(id) is Some(ticket) {
    self.will_tickets.remove(id)
    ticket.release().unwrap()
  }
  self.mark_snapshot_dirty()
  true
}

///|
pub fn BrokerState::trigger_will(
  self : BrokerState,
  id : Int64,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  retention : @session.Retention,
) -> Bool {
  let record = match self.wills.get(id) {
    Some(value) if value.state == WillArmed => value
    _ => return false
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
    Err(_) => return false
  }
  self.wills.set(id, {
    ..record,
    state: WillPending,
    trigger_wall_ms: Some(now_wall_ms),
    due: Some(due),
    revision: record.revision + 1L,
  })
  if self.active_will_by_client.get(record.client_id) == Some(id) {
    self.active_will_by_client.remove(record.client_id)
  }
  self.mark_snapshot_dirty()
  true
}

///|
pub fn BrokerState::next_due_will(
  self : BrokerState,
  now_mono_ms : Int64,
) -> Int64? {
  let mut due_id : Int64? = None
  let mut due_time = 9223372036854775807L
  for id, record in self.wills {
    if record.state == WillPending &&
      record.due is Some(deadline) &&
      deadline.remaining_at(now_mono_ms) == 0L &&
      (
        deadline.mono_due_ms < due_time ||
        (
          deadline.mono_due_ms == due_time &&
          (due_id is None || id < due_id.unwrap())
        )
      ) {
      due_id = Some(id)
      due_time = deadline.mono_due_ms
    }
  }
  due_id
}

///|
pub fn BrokerState::publish_due_will(
  self : BrokerState,
  id : Int64,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[Array[BrokerAction], RouterError] {
  let record = match self.wills.get(id) {
    Some(value) if value.state == WillPending &&
      value.due is Some(deadline) &&
      deadline.remaining_at(now_mono_ms) == 0L => value
    _ => return Ok([])
  }
  if self.security_policy is Some(policy) &&
    (
      !policy.allows_principal(record.owner) ||
      !policy.can_write_topic(record.owner, record.template.topic)
    ) {
    ignore(self.cancel_will(id))
    return Ok([])
  }
  let expiry = match record.template.message_expiry_seconds {
    None => None
    Some(seconds) =>
      match @session.Deadline::from_seconds(now_mono_ms, now_wall_ms, seconds) {
        Ok(value) => Some(value)
        Err(_) => return Err(InvariantViolation("Will expiry clock overflow"))
      }
  }
  let metadata = {
    ..record.template.metadata.copy(),
    publisher_client_id: Some(record.client_id),
    expiry,
  }
  let input : PublishInput = {
    origin: Will(record.client_id),
    topic: record.template.topic,
    payload: record.template.payload,
    qos: record.template.qos,
    retain: record.template.retain,
  }
  let actions = self.publish_input(input, metadata~, now_mono_ms~)
  match actions {
    Ok(value) => {
      ignore(self.cancel_will(id))
      Ok(value)
    }
    Err(error) => Err(error)
  }
}

///|
pub fn BrokerState::cancel_wills_for_session(
  self : BrokerState,
  client_id : @session.ClientId,
  incarnation : Int64,
  now_mono_ms? : Int64 = @budget.monotonic_ms(),
) -> Int {
  let ids : Array[Int64] = []
  for id, record in self.wills {
    if record.client_id == client_id &&
      record.session_incarnation == incarnation &&
      !(record.state == WillPending &&
      record.due is Some(due) &&
      due.remaining_at(now_mono_ms) == 0L) {
      ids.push(id)
    }
  }
  for id in ids {
    ignore(self.cancel_will(id))
  }
  ids.length()
}

///|
pub fn BrokerState::will_session_retention(
  self : BrokerState,
  id : Int64,
) -> @session.Retention? {
  let record = match self.wills.get(id) {
    Some(value) => value
    None => return None
  }
  self.session_retention(record.client_id)
}

///|
pub fn BrokerState::will_effective_delay_zero(
  self : BrokerState,
  id : Int64,
  retention : @session.Retention,
) -> Bool {
  let record = match self.wills.get(id) {
    Some(value) if value.state == WillArmed => value
    _ => return false
  }
  match retention {
    @session.DropOnClose => true
    @session.FiniteV5(expiry) if expiry < record.template.delay_seconds =>
      expiry == 0U
    _ => record.template.delay_seconds == 0U
  }
}

///|
pub fn BrokerState::will_counts(self : BrokerState) -> (Int, Int) {
  let mut armed = 0
  let mut pending = 0
  for _, record in self.wills {
    if record.state == WillArmed {
      armed += 1
    } else {
      pending += 1
    }
  }
  (armed, pending)
}

///|
pub fn BrokerState::cancel_wills_for_incarnation(
  self : BrokerState,
  client_id : @session.ClientId,
  incarnation : Int64,
) -> Int {
  let ids : Array[Int64] = []
  for id, record in self.wills {
    if record.client_id == client_id &&
      record.session_incarnation == incarnation {
      ids.push(id)
    }
  }
  for id in ids {
    ignore(self.cancel_will(id))
  }
  ids.length()
}
