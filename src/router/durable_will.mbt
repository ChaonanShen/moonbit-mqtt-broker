///|
pub(all) enum DurableWillKind {
  Trigger
  Cancel
  Publish
} derive(Eq, Debug)

///|
pub struct DurableWillPlan {
  broker : BrokerState
  id : Int64
  before : Mqtt5WillRecord
  record_persisted : Bool
  after : Mqtt5WillRecord?
  publish : DurablePublishPlan?
  kind : DurableWillKind
  now_mono_ms : Int64
  now_wall_ms : Int64
  mut finished : Bool
}

///|
pub fn BrokerState::prepare_durable_will_trigger(
  self : BrokerState,
  id : Int64,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  retention : @session.Retention,
) -> Result[DurableWillPlan, RouterError] {
  let before = match self.wills.get(id) {
    Some(value) if value.state == WillArmed => value
    _ => return Err(InvariantViolation("Will is not armed"))
  }
  let seconds = match retention {
    @session.DropOnClose => 0U
    @session.FiniteV5(expiry) if expiry < before.template.delay_seconds =>
      expiry
    _ => before.template.delay_seconds
  }
  let due = match
    @session.Deadline::from_seconds(now_mono_ms, now_wall_ms, seconds) {
    Ok(value) => value
    Err(_) => return Err(InvariantViolation("Will delay clock overflow"))
  }
  if before.revision == 9223372036854775807L ||
    !self.will_expiry.can_set(id.to_string()) {
    return Err(InvariantViolation("Will expiry index capacity reached"))
  }
  Ok({
    broker: self,
    id,
    before,
    record_persisted: self.session_mode(before.client_id) ==
    Some(@session.Persistent),
    after: Some({
      ..before,
      state: WillPending,
      trigger_wall_ms: Some(now_wall_ms),
      due: Some(due),
      revision: before.revision + 1L,
    }),
    publish: None,
    kind: Trigger,
    now_mono_ms,
    now_wall_ms,
    finished: false,
  })
}

///|
pub fn BrokerState::prepare_durable_will_cancel(
  self : BrokerState,
  id : Int64,
) -> Result[DurableWillPlan, RouterError] {
  let before = match self.wills.get(id) {
    Some(value) => value
    None => return Err(InvariantViolation("Will not found"))
  }
  Ok({
    broker: self,
    id,
    before,
    record_persisted: before.state == WillPending ||
    self.session_mode(before.client_id) == Some(@session.Persistent),
    after: None,
    publish: None,
    kind: Cancel,
    now_mono_ms: 0L,
    now_wall_ms: 0L,
    finished: false,
  })
}

///|
pub fn BrokerState::prepare_durable_will_publish(
  self : BrokerState,
  id : Int64,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  generations : Map[@session.ClientId, Int64],
) -> Result[DurableWillPlan, RouterError] {
  let before = match self.wills.get(id) {
    Some(value) if value.state == WillPending &&
      value.due is Some(due) &&
      due.remaining_at(now_mono_ms) == 0L => value
    _ => return Err(InvariantViolation("Will is not due"))
  }
  if self.security_policy is Some(policy) &&
    (
      !policy.allows_principal(before.owner) ||
      !policy.can_write_topic(before.owner, before.template.topic)
    ) {
    return self.prepare_durable_will_cancel(id)
  }
  let expiry = match before.template.message_expiry_seconds {
    None => None
    Some(seconds) =>
      match @session.Deadline::from_seconds(now_mono_ms, now_wall_ms, seconds) {
        Ok(value) => Some(value)
        Err(_) => return Err(InvariantViolation("Will expiry clock overflow"))
      }
  }
  let metadata : @session.MessageMetadata = {
    ..before.template.metadata.copy(),
    publisher_client_id: Some(before.client_id),
    expiry,
  }
  let input : PublishInput = {
    origin: Will(before.client_id),
    topic: before.template.topic,
    payload: before.template.payload,
    qos: before.template.qos,
    retain: before.template.retain,
  }
  let publish = match
    self.prepare_durable_publish(input, generations, metadata~, now_mono_ms~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    broker: self,
    id,
    before,
    record_persisted: true,
    after: None,
    publish: Some(publish),
    kind: Publish,
    now_mono_ms,
    now_wall_ms,
    finished: false,
  })
}

///|
fn durable_will_snapshot(
  record : Mqtt5WillRecord,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[SnapshotWillV5, RouterError] {
  let template = @session.SessionMessage::new(
    record.template.topic,
    record.template.payload,
    record.template.retain,
    qos=record.template.qos,
    metadata=record.template.metadata,
  )
  let message = match v5_snapshot_message(template, now_mono_ms, now_wall_ms) {
    Ok(value) => value
    Err(_) => return Err(InvariantViolation("cannot snapshot Will"))
  }
  let due_clock = match record.due {
    None => None
    Some(value) =>
      match v5_snapshot_clock(value, now_mono_ms, now_wall_ms) {
        Ok(clock) => Some(clock)
        Err(_) =>
          return Err(InvariantViolation("cannot snapshot Will deadline"))
      }
  }
  Ok({
    id: record.id,
    owner_principal: record.owner.storage_value(),
    client_id: record.client_id.value(),
    session_incarnation: record.session_incarnation,
    state: if record.state == WillArmed {
      0
    } else {
      1
    },
    message_template: message,
    delay_seconds: record.template.delay_seconds,
    will_message_expiry_seconds: record.template.message_expiry_seconds,
    trigger_wall_ms: record.trigger_wall_ms,
    due_clock,
    policy_sequence: record.policy_sequence,
    revision: record.revision,
  })
}

///|
pub fn DurableWillPlan::delta_v5(
  self : DurableWillPlan,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[DurableDeltaV5, RouterError] {
  let delta = match self.publish {
    Some(value) =>
      match value.delta_v5(now_mono_ms, now_wall_ms) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
    None => DurableDeltaV5::empty()
  }
  if self.after is Some(value) {
    let saved = match
      durable_will_snapshot(value, self.now_mono_ms, self.now_wall_ms) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    delta.will_puts.push({
      expected_revision: if self.record_persisted {
        self.before.revision
      } else {
        0L
      },
      will: saved,
    })
  } else if self.record_persisted {
    delta.will_deletes.push({
      id: self.id,
      expected_revision: self.before.revision,
    })
  }
  Ok(delta)
}

///|
pub fn DurableWillPlan::commit(
  self : DurableWillPlan,
) -> Result[Array[BrokerAction], RouterError] {
  if self.finished || self.broker.wills.get(self.id) != Some(self.before) {
    return Err(InvariantViolation("Will changed before commit"))
  }
  let actions = match self.publish {
    Some(value) =>
      match value.commit() {
        Ok(result) => result
        Err(error) => return Err(error)
      }
    None => []
  }
  if self.kind == Trigger {
    if !self.broker.trigger_will(
        self.id,
        self.now_mono_ms,
        self.now_wall_ms,
        self.broker
        .session_retention(self.before.client_id)
        .unwrap_or(@session.DropOnClose),
      ) {
      return Err(InvariantViolation("Will trigger failed after commit"))
    }
  } else if !self.broker.cancel_will(self.id) {
    return Err(InvariantViolation("Will cancel failed after commit"))
  }
  self.finished = true
  Ok(actions)
}

///|
pub fn DurableWillPlan::cancel(self : DurableWillPlan) -> Unit {
  if !self.finished {
    if self.publish is Some(value) {
      value.cancel()
    }
    self.finished = true
  }
}

///|
pub fn BrokerState::next_armed_will(
  self : BrokerState,
  active : (@session.ClientId) -> Bool,
) -> Int64? {
  let mut selected : Int64? = None
  for id, record in self.wills {
    if record.state == WillArmed &&
      !active(record.client_id) &&
      (selected is None || id < selected.unwrap()) {
      selected = Some(id)
    }
  }
  selected
}
