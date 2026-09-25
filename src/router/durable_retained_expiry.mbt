///|
pub struct DurableRetainedExpiryPlan {
  broker : BrokerState
  topic : @topic.TopicName
  revision : Int64
  target_bytes : Int64
  replacement : @budget.Replacement
  mut finished : Bool
}

///|
pub fn BrokerState::next_expired_retained(
  self : BrokerState,
  now_mono_ms : Int64,
) -> @topic.TopicName? {
  self.retained.next_expired(now_mono_ms)
}

///|
pub fn BrokerState::next_expired_retained_cost(
  self : BrokerState,
  now_mono_ms : Int64,
) -> Int64? {
  self
  .next_expired_retained(now_mono_ms)
  .map(topic => self.retained.cost_at(topic))
}

///|
pub fn BrokerState::prepare_durable_retained_expiry(
  self : BrokerState,
  topic : @topic.TopicName,
  now_mono_ms : Int64,
) -> Result[DurableRetainedExpiryPlan, RouterError] {
  let message = match self.retained.peek(topic) {
    Some(value) => value
    None => return Err(InvariantViolation("retained expiry target absent"))
  }
  if !(message.metadata.expiry is Some(deadline) &&
    deadline.remaining_at(now_mono_ms) == 0L) {
    return Err(InvariantViolation("retained expiry target not due"))
  }
  let revision = self.retained.revision(topic).unwrap()
  let target_bytes = self.resources.retained_bytes -
    self.retained.cost_at(topic)
  let replacement = match
    self.resources.ledger.prepare_deferred_replacement([
      (
        self.resources.retained_ticket,
        [self.resources.retained_pool.allocation(target_bytes)],
      ),
    ]) {
    Ok(value) => value
    Err(error) => return Err(ByteResourceLimit(error))
  }
  Ok({
    broker: self,
    topic,
    revision,
    target_bytes,
    replacement,
    finished: false,
  })
}

///|
pub fn DurableRetainedExpiryPlan::delta_v5(
  self : DurableRetainedExpiryPlan,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[DurableDeltaV5, RouterError] {
  ignore(now_mono_ms)
  Ok({
    ..DurableDeltaV5::empty(),
    new_clock_floor: if now_wall_ms > self.broker.clock_floor_wall_ms {
      Some(now_wall_ms)
    } else {
      None
    },
    retained_deletes: [
      { topic: self.topic.value(), expected_revision: self.revision },
    ],
  })
}

///|
pub fn DurableRetainedExpiryPlan::commit(
  self : DurableRetainedExpiryPlan,
) -> Result[Array[BrokerAction], RouterError] {
  if self.finished ||
    self.broker.retained.revision(self.topic) != Some(self.revision) {
    return Err(InvariantViolation("retained expiry target changed"))
  }
  if self.replacement.commit() is Err(_) {
    return Err(InvariantViolation("retained expiry budget changed"))
  }
  self.broker.resources.retained_bytes = self.target_bytes
  self.broker.retained.remove(self.topic)
  if self.broker.admin_sessions is Some(index) {
    index.remove_retained(self.topic)
  }
  self.broker.mark_snapshot_dirty()
  self.finished = true
  Ok([])
}

///|
pub fn DurableRetainedExpiryPlan::cancel(
  self : DurableRetainedExpiryPlan,
) -> Unit {
  if !self.finished {
    self.replacement.rollback().unwrap()
    self.finished = true
  }
}

///|
pub fn BrokerState::expire_one_retained_v5(
  self : BrokerState,
  now_mono_ms : Int64,
) -> Result[Bool, RouterError] {
  let topic = match self.next_expired_retained(now_mono_ms) {
    Some(value) => value
    None => return Ok(false)
  }
  let plan = match self.prepare_durable_retained_expiry(topic, now_mono_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match plan.commit() {
    Ok(_) => Ok(true)
    Err(error) => {
      plan.cancel()
      Err(error)
    }
  }
}
