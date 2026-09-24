///|
pub struct DurableReconcilePlan {
  broker : BrokerState
  client_id : @session.ClientId
  incarnation : Int64
  before_revision : Int64
  filter : @topic.TopicFilter?
  head : @session.SessionMessage?
  pending_index : Int
  remaining : Array[@session.SessionMessage]
  next_subscription_bytes : Int64
  next_pending_bytes : Int64
  replacement : @budget.Replacement
  scratch : @budget.Ticket
  delta : DurableReconcileDelta
  mut finished : Bool
}

///|
pub fn DurableReconcilePlan::delta(
  self : DurableReconcilePlan,
) -> DurableReconcileDelta {
  self.delta
}

///|
/// Prepare one local cleanup without serializing the entire Session queue.
pub fn BrokerState::prepare_durable_reconcile(
  self : BrokerState,
  client_id : @session.ClientId,
  change : DurablePolicyChange,
  generation : Int64,
) -> Result[DurableReconcilePlan, RouterError] {
  let session = match self.sessions.get(client_id) {
    Some(value) if value.mode() == @session.Persistent => value
    _ => return Err(InvalidSessionState(client_id))
  }
  let incarnation = match self.policy_session_incarnation(client_id) {
    Some(value) => value
    None => return Err(InvariantViolation("policy index unavailable"))
  }
  let policy = match self.security_policy {
    Some(value) => value
    None =>
      return Err(InvariantViolation("current security policy unavailable"))
  }
  if generation < 1L {
    return Err(InvariantViolation("invalid policy WAL Session generation"))
  }
  let change = match change {
    DropPendingHead(topic, qos, payload_bytes) =>
      DropPendingAt(0, topic, qos, payload_bytes)
    value => value
  }
  let principal = session.owner()
  let owner = self.resources.owners.get(client_id).unwrap()
  let mut filter : @topic.TopicFilter? = None
  let mut head : @session.SessionMessage? = None
  let mut pending_index = 0
  let mut remaining : Array[@session.SessionMessage] = []
  let mut next_usage = owner.usage
  let mut scratch_cost = 256L
  match change {
    DropSubscription(text) => {
      let parsed = match @topic.TopicFilter::new(text) {
        Ok(value) => value
        Err(_) => return Err(InvariantViolation("invalid policy filter"))
      }
      if self.subscriptions.qos(client_id, parsed) is None ||
        (
          policy.allows_principal(principal) &&
          policy.can_read_filter(principal, parsed)
        ) {
        return Err(InvariantViolation("policy subscription is not revoked"))
      }
      let cost = @budget.subscription_cost(text)
      if cost > owner.usage.subscriptions {
        return Err(InvariantViolation("policy subscription budget mismatch"))
      }
      next_usage = {
        ..owner.usage,
        subscriptions: owner.usage.subscriptions - cost,
      }
      scratch_cost += @budget.utf8_bytes(text)
      filter = Some(parsed)
    }
    DropPendingAt(index, topic, qos, payload_bytes) => {
      let current = match session.pending_item_reference(index) {
        Some(value) => value
        None => return Err(InvariantViolation("policy pending item missing"))
      }
      if current.topic.value() != topic ||
        snapshot_qos(current.qos) != qos ||
        current.payload.length() != payload_bytes ||
        (
          policy.allows_principal(principal) &&
          policy.can_read_topic(principal, current.topic)
        ) {
        return Err(InvariantViolation("policy pending item is not revoked"))
      }
      let cost = current.cost()
      if cost > owner.usage.pending {
        return Err(InvariantViolation("policy pending budget mismatch"))
      }
      scratch_cost += session.pending_count().to_int64() * 16L +
        @budget.utf8_bytes(topic)
      if scratch_cost > 1048576L {
        return Err(InvariantViolation("policy reconcile turn exceeds byte cap"))
      }
      remaining = session.pending_without_item_for_policy(index)
      pending_index = index
      next_usage = { ..owner.usage, pending: owner.usage.pending - cost }
      head = Some(current)
    }
    DropPendingHead(_, _, _) =>
      return Err(InvariantViolation("unreachable policy head conversion"))
  }
  let scratch = match self.reserve_scratch(scratch_cost) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let replacement = match
    self.resources.ledger.prepare_deferred_replacement([
      (owner.ticket, owner.allocations(next_usage)),
    ]) {
    Ok(value) => value
    Err(error) => {
      scratch.release().unwrap()
      return Err(ByteResourceLimit(error))
    }
  }
  Ok({
    broker: self,
    client_id,
    incarnation,
    before_revision: self.snapshot_revision(),
    filter,
    head,
    pending_index,
    remaining,
    next_subscription_bytes: next_usage.subscriptions,
    next_pending_bytes: next_usage.pending,
    replacement,
    scratch,
    delta: {
      client_id: client_id.value(),
      expected_generation: generation,
      change,
    },
    finished: false,
  })
}

///|
pub fn DurableReconcilePlan::commit(
  self : DurableReconcilePlan,
) -> Result[Array[BrokerAction], RouterError] {
  if self.finished ||
    self.broker.snapshot_revision() != self.before_revision ||
    self.broker.policy_session_incarnation(self.client_id) !=
    Some(self.incarnation) {
    return Err(InvariantViolation("policy reconcile candidate changed"))
  }
  let session = match self.broker.sessions.get(self.client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(self.client_id))
  }
  match self.delta.change {
    DropSubscription(_) =>
      if self.filter is None ||
        self.broker.subscriptions.qos(self.client_id, self.filter.unwrap())
        is None {
        return Err(InvariantViolation("policy subscription changed"))
      }
    DropPendingAt(_, _, _, _) =>
      if self.head is None ||
        session.pending_item_reference(self.pending_index) is None ||
        !physical_equal(
          session.pending_item_reference(self.pending_index).unwrap(),
          self.head.unwrap(),
        ) {
        return Err(InvariantViolation("policy pending item changed"))
      }
    DropPendingHead(_, _, _) =>
      return Err(InvariantViolation("unreachable policy head conversion"))
  }
  if self.replacement.commit() is Err(_) {
    return Err(InvariantViolation("policy reconcile budget owner changed"))
  }
  match self.delta.change {
    DropSubscription(_) => {
      let filter = self.filter.unwrap()
      ignore(self.broker.subscriptions.remove(self.client_id, filter))
      if self.broker.admin_sessions is Some(index) {
        index.remove_subscription(self.client_id, filter)
      }
    }
    DropPendingAt(_, _, _, _) => {
      if !session.discard_pending_item_prepared(
          self.pending_index,
          self.head.unwrap(),
          self.remaining,
        ) {
        return Err(InvariantViolation("policy pending release changed"))
      }
      self.broker.pending_qos1_total -= 1
    }
    DropPendingHead(_, _, _) =>
      return Err(InvariantViolation("unreachable policy head conversion"))
  }
  let owner = self.broker.resources.owners.get(self.client_id).unwrap()
  owner.usage = {
    ..owner.usage,
    subscriptions: self.next_subscription_bytes,
    pending: self.next_pending_bytes,
  }
  self.broker.mark_snapshot_dirty()
  self.finished = true
  self.scratch.release().unwrap()
  Ok([])
}

///|
pub fn DurableReconcilePlan::cancel(self : DurableReconcilePlan) -> Unit {
  if !self.finished {
    self.replacement.rollback().unwrap()
    self.scratch.release().unwrap()
    self.finished = true
  }
}
