///|
pub struct DurablePendingExpiryPlan {
  broker : BrokerState
  client_id : @session.ClientId
  index : Int
  expected : @session.SessionMessage
  remaining : Array[@session.SessionMessage]
  candidate : @session.ClientSession
  replacement : @budget.Replacement
  mut finished : Bool
}

///|
pub fn BrokerState::next_expired_pending(
  self : BrokerState,
  now_mono_ms : Int64,
) -> (@session.ClientId, Int)? {
  let mut selected : (@session.ClientId, Int, Int64)? = None
  for client_id, session in self.sessions {
    if session.next_expired_pending_item(now_mono_ms) is Some((index, due)) &&
      (
        selected is None ||
        due < selected.unwrap().2 ||
        (
          due == selected.unwrap().2 &&
          compare_utf8_for_sort(client_id.value(), selected.unwrap().0.value()) <
          0
        )
      ) {
      selected = Some((client_id, index, due))
    }
  }
  selected.map(value => (value.0, value.1))
}

///|
pub fn BrokerState::prepare_durable_pending_expiry(
  self : BrokerState,
  client_id : @session.ClientId,
  index : Int,
  now_mono_ms : Int64,
) -> Result[DurablePendingExpiryPlan, RouterError] {
  let session = match self.sessions.get(client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(client_id))
  }
  let expected = match session.pending_item_reference(index) {
    Some(value) => value
    None => return Err(InvariantViolation("pending expiry target absent"))
  }
  if !(expected.metadata.expiry is Some(deadline) &&
    deadline.remaining_at(now_mono_ms) == 0L) {
    return Err(InvariantViolation("pending expiry target not due"))
  }
  let remaining = session.pending_without_item_for_policy(index)
  let candidate = session.copy()
  let candidate_expected = candidate.pending_item_reference(index).unwrap()
  let candidate_remaining = candidate.pending_without_item_for_policy(index)
  if !candidate.discard_pending_item_prepared(
      index, candidate_expected, candidate_remaining,
    ) {
    return Err(InvariantViolation("pending expiry candidate changed"))
  }
  let owner = self.resources.owners.get(client_id).unwrap()
  let usage : ResourceUsage = {
    ..owner.usage,
    pending: candidate.pending_bytes(),
  }
  let replacement = match
    self.resources.ledger.prepare_deferred_replacement([
      (owner.ticket, owner.allocations(usage)),
    ]) {
    Ok(value) => value
    Err(error) => return Err(ByteResourceLimit(error))
  }
  Ok({
    broker: self,
    client_id,
    index,
    expected,
    remaining,
    candidate,
    replacement,
    finished: false,
  })
}

///|
pub fn DurablePendingExpiryPlan::delta_v5(
  self : DurablePendingExpiryPlan,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[DurableDeltaV5, RouterError] {
  let session_puts : Array[Mqtt5SessionPut] = []
  if self.candidate.mode() == @session.Persistent {
    let put = match
      self.broker.session_put_v5(
        self.client_id,
        self.candidate,
        now_mono_ms,
        now_wall_ms,
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
    session_puts,
  })
}

///|
pub fn DurablePendingExpiryPlan::commit(
  self : DurablePendingExpiryPlan,
) -> Result[Array[BrokerAction], RouterError] {
  if self.finished {
    return Err(InvariantViolation("pending expiry already finished"))
  }
  let session = match self.broker.sessions.get(self.client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(self.client_id))
  }
  if session.pending_item_reference(self.index) is None ||
    !physical_equal(
      session.pending_item_reference(self.index).unwrap(),
      self.expected,
    ) {
    return Err(InvariantViolation("pending expiry target changed"))
  }
  if self.replacement.commit() is Err(_) {
    return Err(InvariantViolation("pending expiry budget changed"))
  }
  if !session.discard_pending_item_prepared(
      self.index,
      self.expected,
      self.remaining,
    ) {
    return Err(InvariantViolation("pending expiry removal failed"))
  }
  let owner = self.broker.resources.owners.get(self.client_id).unwrap()
  owner.usage = { ..owner.usage, pending: session.pending_bytes() }
  self.broker.pending_qos1_total -= 1
  if session.mode() == @session.Persistent {
    self.broker.mark_snapshot_dirty()
  }
  self.finished = true
  Ok([])
}

///|
pub fn DurablePendingExpiryPlan::cancel(
  self : DurablePendingExpiryPlan,
) -> Unit {
  if !self.finished {
    self.replacement.rollback().unwrap()
    self.finished = true
  }
}

///|
pub fn BrokerState::expire_one_pending_v5(
  self : BrokerState,
  now_mono_ms : Int64,
) -> Result[Bool, RouterError] {
  let (client_id, index) = match self.next_expired_pending(now_mono_ms) {
    Some(value) => value
    None => return Ok(false)
  }
  let plan = match
    self.prepare_durable_pending_expiry(client_id, index, now_mono_ms) {
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
