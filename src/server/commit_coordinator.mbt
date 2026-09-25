///|
pub(all) enum PreparedBrokerMutation {
  Noop
  Publish(@router.DurablePublishPlan)
  PublishWithWill(@router.DurablePublishPlan, @budget.Ticket?)
  Ack(@router.DurableAckPlan)
  Activation(@router.DurableActivationPlan)
  ActivationWithWill(@router.DurableActivationPlan, @budget.Ticket?)
  Lifecycle(@router.DurableLifecyclePlan)
  Subscribe(@router.DurableSubscribePlan)
  Unsubscribe(@router.DurableUnsubscribePlan)
  PolicyRecord(@persistence.WalPolicyRecord)
  PolicyReconcile(@router.DurableReconcilePlan)
}

///|
fn PreparedBrokerMutation::delta(
  self : PreparedBrokerMutation,
) -> @router.DurableDelta {
  match self {
    Noop => @router.DurableDelta::empty()
    Publish(value) => value.delta()
    PublishWithWill(value, _) => value.delta()
    Ack(value) => value.delta()
    Activation(value) => value.delta()
    ActivationWithWill(value, _) => value.delta()
    Lifecycle(value) => value.delta()
    Subscribe(value) => value.delta()
    Unsubscribe(value) => value.delta()
    PolicyRecord(_) | PolicyReconcile(_) => @router.DurableDelta::empty()
  }
}

///|
fn PreparedBrokerMutation::commit(
  self : PreparedBrokerMutation,
) -> Result[Array[@router.BrokerAction], @router.RouterError] {
  match self {
    Noop => Ok([])
    Publish(value) => value.commit()
    PublishWithWill(value, _) => value.commit()
    Ack(value) => value.commit()
    Activation(value) => value.commit()
    ActivationWithWill(value, _) => value.commit()
    Lifecycle(value) => value.commit()
    Subscribe(value) => value.commit()
    Unsubscribe(value) => value.commit()
    PolicyRecord(_) => Ok([])
    PolicyReconcile(value) => value.commit()
  }
}

///|
fn PreparedBrokerMutation::cancel(self : PreparedBrokerMutation) -> Unit {
  match self {
    Noop => ()
    Publish(value) => value.cancel()
    PublishWithWill(value, ticket) => {
      value.cancel()
      release_optional(ticket)
    }
    Ack(value) => value.cancel()
    Activation(value) => value.cancel()
    ActivationWithWill(value, ticket) => {
      value.cancel()
      release_optional(ticket)
    }
    Lifecycle(value) => value.cancel()
    Subscribe(value) => value.cancel()
    Unsubscribe(value) => value.cancel()
    PolicyRecord(_) => ()
    PolicyReconcile(value) => value.cancel()
  }
}

///|
pub(all) enum CommitSubmitError {
  CommitBusy
  CommitFenced
  CommitEncoding
  CommitBudget
  CommitWriterUnavailable
  CommitLsnExhausted
} derive(Eq, Debug)

///|
pub enum CommitPollResult {
  NoCommitCompletion
  CommitReleased(
    Array[RuntimeAction],
    Array[@router.DurableDelta],
    Array[ConnectionId?]
  )
  CommitFencedResult(String)
  CommitCheckpointPublished(Int64, Int64)
  CommitCheckpointFailed(String, Bool)
  CommitPolicyCapabilityReady
}

///|
pub struct PendingCommit {
  lsn : Int64
  plan : PreparedBrokerMutation
  delta : @router.DurableDelta
  encoded : Bytes
  after_commit : (Array[@router.BrokerAction]) -> Array[RuntimeAction]
  ticket : @budget.Ticket
  pending_bytes : Int64
  connection_id : ConnectionId?
}

///|
pub struct PendingBatch {
  first_lsn : Int64
  last_lsn : Int64
  entries : Array[PendingCommit]
  submitted_at_ms : Int64
}

///|
pub struct CommitCoordinator {
  writer : @persistence.WalWriter
  pool : @budget.Pool
  broker : @router.BrokerState?
  max_delta_bytes : Int
  writer_epoch : Int64
  commit_timeout_ms : Int64
  mut committed_lsn : Int64
  mut last_released_lsn : Int64
  mut last_batch_first_lsn : Int64
  mut last_batch_last_lsn : Int64
  collecting : Array[PendingCommit]
  mut collecting_started_ms : Int64
  mut collecting_bytes : Int64
  mut submitted : PendingBatch?
  mut policy_upgrade_pending : Bool
  mut fenced : Bool
}

///|
pub fn CommitCoordinator::new(
  writer : @persistence.WalWriter,
  ledger : @budget.Ledger,
  pending_limit_bytes : Int64,
  max_delta_bytes : Int,
  writer_epoch : Int64,
  committed_lsn : Int64,
  broker? : @router.BrokerState,
  commit_timeout_ms? : Int64 = 5000L,
) -> Result[CommitCoordinator, CommitSubmitError] {
  if pending_limit_bytes < 1L ||
    max_delta_bytes < 64 ||
    writer_epoch < 1L ||
    committed_lsn < 0L ||
    committed_lsn == 9223372036854775807L ||
    writer.committed_lsn() != committed_lsn {
    return Err(CommitLsnExhausted)
  }
  let pool = match ledger.pool(WalPending, pending_limit_bytes) {
    Ok(value) => value
    Err(_) => return Err(CommitBudget)
  }
  Ok({
    writer,
    pool,
    broker,
    max_delta_bytes,
    writer_epoch,
    commit_timeout_ms,
    committed_lsn,
    last_released_lsn: committed_lsn,
    last_batch_first_lsn: 0L,
    last_batch_last_lsn: 0L,
    collecting: [],
    collecting_started_ms: 0L,
    collecting_bytes: 0L,
    submitted: None,
    policy_upgrade_pending: false,
    fenced: false,
  })
}

///|
pub fn CommitCoordinator::writer(
  self : CommitCoordinator,
) -> @persistence.WalWriter {
  self.writer
}

///|
pub fn CommitCoordinator::committed_lsn(self : CommitCoordinator) -> Int64 {
  self.committed_lsn
}

///|
pub fn CommitCoordinator::applied_lsn(self : CommitCoordinator) -> Int64 {
  self.last_released_lsn
}

///|
pub fn CommitCoordinator::checkpoint_lsn(self : CommitCoordinator) -> Int64 {
  self.writer.checkpoint_lsn()
}

///|
pub fn CommitCoordinator::checkpoint_generation(
  self : CommitCoordinator,
) -> Int64 {
  self.writer.checkpoint_generation()
}

///|
pub fn CommitCoordinator::checkpoint_active(self : CommitCoordinator) -> Bool {
  self.writer.checkpoint_active()
}

///|
pub fn CommitCoordinator::is_fenced(self : CommitCoordinator) -> Bool {
  self.fenced || self.writer.is_fenced()
}

///|
pub fn CommitCoordinator::has_pending(self : CommitCoordinator) -> Bool {
  self.submitted is Some(_) ||
  !self.collecting.is_empty() ||
  self.policy_upgrade_pending
}

///|
pub fn CommitCoordinator::policy_required(self : CommitCoordinator) -> Bool {
  self.writer.policy_required()
}

///|
pub fn CommitCoordinator::policy_state(
  self : CommitCoordinator,
) -> @persistence.WalPolicyState? {
  self.writer.policy_state()
}

///|
/// The writer serializes the durable capability switch with all WAL writes.
pub fn CommitCoordinator::request_policy_capability(
  self : CommitCoordinator,
) -> Bool {
  if self.is_fenced() || self.has_pending() {
    return false
  }
  if self.writer.policy_required() {
    return true
  }
  if self.writer.submit_policy_capability() {
    self.policy_upgrade_pending = true
    true
  } else {
    false
  }
}

///|
pub fn CommitCoordinator::has_submitted(self : CommitCoordinator) -> Bool {
  self.submitted is Some(_)
}

///|
pub fn CommitCoordinator::is_collecting(self : CommitCoordinator) -> Bool {
  !self.collecting.is_empty() && self.submitted is None
}

///|
pub fn CommitCoordinator::collecting_due(self : CommitCoordinator) -> Bool {
  self.is_collecting() && @async.now() - self.collecting_started_ms >= 2L
}

///|
pub fn CommitCoordinator::check_timeout(
  self : CommitCoordinator,
  now_ms : Int64,
) -> Bool {
  if !self.fenced &&
    self.submitted is Some(batch) &&
    now_ms >= batch.submitted_at_ms &&
    now_ms - batch.submitted_at_ms >= self.commit_timeout_ms {
    self.fenced = true
    return true
  }
  false
}

///|
pub fn CommitCoordinator::contains_connection(
  self : CommitCoordinator,
  id : ConnectionId,
) -> Bool {
  for entry in self.collecting {
    if entry.connection_id == Some(id) {
      return true
    }
  }
  if self.submitted is Some(batch) {
    for entry in batch.entries {
      if entry.connection_id == Some(id) {
        return true
      }
    }
  }
  false
}

///|
pub fn CommitCoordinator::pending_bytes(self : CommitCoordinator) -> Int64 {
  let mut bytes = self.collecting_bytes
  if self.submitted is Some(batch) {
    for entry in batch.entries {
      bytes += entry.pending_bytes
    }
  }
  bytes
}

///|
fn batchable_plan(plan : PreparedBrokerMutation) -> Bool {
  match plan {
    Noop | Publish(_) | Ack(_) | PublishWithWill(_, _) => true
    _ => false
  }
}

///|
fn durable_delta_overlap(
  left : @router.DurableDelta,
  right : @router.DurableDelta,
) -> Bool {
  let sessions : Map[String, Bool] = Map([])
  let topics : Map[String, Bool] = Map([])
  for put in left.session_puts {
    sessions.set(put.session.client_id, true)
  }
  for deletion in left.session_deletes {
    sessions.set(deletion.client_id, true)
  }
  for put in left.retained_puts {
    topics.set(put.topic, true)
  }
  for topic in left.retained_deletes {
    topics.set(topic, true)
  }
  for put in right.session_puts {
    if sessions.contains(put.session.client_id) {
      return true
    }
  }
  for deletion in right.session_deletes {
    if sessions.contains(deletion.client_id) {
      return true
    }
  }
  for put in right.retained_puts {
    if topics.contains(put.topic) {
      return true
    }
  }
  for topic in right.retained_deletes {
    if topics.contains(topic) {
      return true
    }
  }
  false
}

///|
fn durable_count_delta(
  broker : @router.BrokerState,
  delta : @router.DurableDelta,
) -> (Int64, Int64, Int64, Int64)? {
  let mut inflight = 0L
  let mut pending = 0L
  let mut inbound = 0L
  let mut retained = 0L
  for put in delta.session_puts {
    let client = match @session.ClientId::new(put.session.client_id) {
      Ok(value) => value
      Err(_) => return None
    }
    let before = broker.export_session_snapshot(client)
    inflight += put.session.inflight.length().to_int64() -
      before.map(item => item.inflight.length().to_int64()).unwrap_or(0L)
    pending += put.session.pending.length().to_int64() -
      before.map(item => item.pending.length().to_int64()).unwrap_or(0L)
    inbound += put.session.inbound_qos2.length().to_int64() -
      before.map(item => item.inbound_qos2.length().to_int64()).unwrap_or(0L)
  }
  for deletion in delta.session_deletes {
    let client = match @session.ClientId::new(deletion.client_id) {
      Ok(value) => value
      Err(_) => return None
    }
    let before = match broker.export_session_snapshot(client) {
      Some(value) => value
      None => return None
    }
    inflight -= before.inflight.length().to_int64()
    pending -= before.pending.length().to_int64()
    inbound -= before.inbound_qos2.length().to_int64()
  }
  for put in delta.retained_puts {
    let topic = match @topic.TopicName::new(put.topic) {
      Ok(value) => value
      Err(_) => return None
    }
    if !broker.has_retained(topic) {
      retained += 1L
    }
  }
  for topic_name in delta.retained_deletes {
    let topic = match @topic.TopicName::new(topic_name) {
      Ok(value) => value
      Err(_) => return None
    }
    if broker.has_retained(topic) {
      retained -= 1L
    }
  }
  Some((inflight, pending, inbound, retained))
}

///|
fn CommitCoordinator::can_collect(
  self : CommitCoordinator,
  plan : PreparedBrokerMutation,
  delta : @router.DurableDelta,
) -> Bool {
  if self.collecting.is_empty() {
    return true
  }
  if !batchable_plan(plan) || self.collecting.length() >= 64 {
    return false
  }
  for entry in self.collecting {
    if !batchable_plan(entry.plan) || durable_delta_overlap(entry.delta, delta) {
      return false
    }
  }
  let broker = match self.broker {
    Some(value) => value
    None =>
      // Without the broker's global count limits only a receipt-only addition
      // can safely share a batch with already prepared state changes.
      return delta.session_puts.is_empty() &&
        delta.session_deletes.is_empty() &&
        delta.retained_puts.is_empty() &&
        delta.retained_deletes.is_empty()
  }
  let mut inflight = broker.inflight_count().to_int64()
  let mut pending = broker.pending_qos1_count().to_int64()
  let mut inbound = broker.inbound_qos2_count().to_int64()
  let mut retained = broker.retained_count().to_int64()
  for entry in self.collecting {
    let (a, b, c, d) = match durable_count_delta(broker, entry.delta) {
      Some(value) => value
      None => return false
    }
    inflight += a
    pending += b
    inbound += c
    retained += d
  }
  let (a, b, c, d) = match durable_count_delta(broker, delta) {
    Some(value) => value
    None => return false
  }
  inflight += a
  pending += b
  inbound += c
  retained += d
  let config = broker.config()
  inflight >= 0L &&
  inflight <= config.max_inflight_total().to_int64() &&
  pending >= 0L &&
  pending <= config.max_pending_qos1_total().to_int64() &&
  inbound >= 0L &&
  inbound <= config.max_inbound_qos2_total().to_int64() &&
  retained >= 0L &&
  retained <= config.max_retained_messages().to_int64()
}

///|
pub fn CommitCoordinator::submit(
  self : CommitCoordinator,
  plan : PreparedBrokerMutation,
  after_commit : (Array[@router.BrokerAction]) -> Array[RuntimeAction],
  connection_id? : ConnectionId,
) -> Result[Int64, CommitSubmitError] {
  if self.is_fenced() {
    plan.cancel()
    return Err(CommitFenced)
  }
  if self.submitted is Some(_) || self.policy_upgrade_pending {
    plan.cancel()
    return Err(CommitBusy)
  }
  if self.committed_lsn >=
    9223372036854775807L - self.collecting.length().to_int64() {
    plan.cancel()
    self.fenced = true
    return Err(CommitLsnExhausted)
  }
  if plan is PolicyRecord(_) && !self.writer.policy_required() {
    plan.cancel()
    self.fenced = true
    return Err(CommitFenced)
  }
  if plan is PolicyReconcile(_) &&
    !(self.writer.policy_state() is Some({ reconcile_pending: true, .. })) {
    plan.cancel()
    self.fenced = true
    return Err(CommitFenced)
  }
  let delta = plan.delta()
  if !self.can_collect(plan, delta) {
    plan.cancel()
    return Err(CommitBusy)
  }
  let encoded = match plan {
    PolicyRecord(record) =>
      match @persistence.encode_wal_policy_record(record) {
        Ok(value) => value
        Err(_) => {
          plan.cancel()
          return Err(CommitEncoding)
        }
      }
    PolicyReconcile(value) =>
      match @persistence.encode_wal_reconcile(value.delta()) {
        Ok(bytes) => bytes
        Err(_) => {
          plan.cancel()
          return Err(CommitEncoding)
        }
      }
    _ =>
      match
        @persistence.encode_durable_delta(delta, max_bytes=self.max_delta_bytes) {
        Ok(value) => value
        Err(_) => {
          plan.cancel()
          return Err(CommitEncoding)
        }
      }
  }
  let frame_overhead = (self.collecting.length().to_int64() + 1L) * 21L + 41L
  if encoded.length().to_int64() >
    8388608L - frame_overhead - self.collecting_bytes {
    plan.cancel()
    return Err(CommitBusy)
  }
  let pending_bytes = encoded.length().to_int64() + 128L
  let ticket = match self.pool.reserve(pending_bytes) {
    Ok(value) => value
    Err(_) => {
      plan.cancel()
      return Err(CommitBudget)
    }
  }
  if self.collecting.is_empty() {
    self.collecting_started_ms = @async.now()
  }
  let lsn = self.committed_lsn + self.collecting.length().to_int64() + 1L
  self.collecting.push({
    lsn,
    plan,
    delta,
    encoded,
    after_commit,
    ticket,
    pending_bytes,
    connection_id,
  })
  self.collecting_bytes += encoded.length().to_int64()
  if self.collecting.length() >= 64 ||
    self.collecting_bytes >= 8388608L ||
    !batchable_plan(plan) {
    if !self.flush() {
      return Err(CommitWriterUnavailable)
    }
  }
  Ok(lsn)
}

///|
pub fn CommitCoordinator::flush(self : CommitCoordinator) -> Bool {
  if self.is_fenced() ||
    self.submitted is Some(_) ||
    self.policy_upgrade_pending {
    return false
  }
  if self.collecting.is_empty() {
    return true
  }
  let transactions : Array[@persistence.WalTransaction] = []
  for entry in self.collecting {
    transactions.push({ lsn: entry.lsn, delta: entry.encoded })
  }
  let first_lsn = self.collecting[0].lsn
  let last_lsn = self.collecting[self.collecting.length() - 1].lsn
  let batch : @persistence.WalBatch = {
    previous_lsn: self.committed_lsn,
    transactions,
  }
  if !self.writer.submit({ writer_epoch: self.writer_epoch, batch }) {
    for entry in self.collecting {
      entry.plan.cancel()
      entry.ticket.release().unwrap()
    }
    self.collecting.clear()
    self.collecting_bytes = 0L
    self.fenced = true
    return false
  }
  self.submitted = Some({
    first_lsn,
    last_lsn,
    entries: self.collecting.copy(),
    submitted_at_ms: @async.now(),
  })
  self.collecting.clear()
  self.collecting_bytes = 0L
  true
}

///|
pub fn CommitCoordinator::submit_checkpoint(
  self : CommitCoordinator,
  checkpoint : @persistence.WalCheckpoint,
) -> Bool {
  if self.is_fenced() ||
    self.has_pending() ||
    checkpoint.lsn != self.last_released_lsn {
    return false
  }
  self.writer.submit_checkpoint(checkpoint)
}

///|
pub fn CommitCoordinator::poll(self : CommitCoordinator) -> CommitPollResult {
  if self.collecting_due() && !self.flush() {
    return CommitFencedResult("group-commit-submit")
  }
  let completion = match self.writer.poll() {
    Some(value) => value
    None => return NoCommitCompletion
  }
  if self.fenced {
    if self.submitted is Some(batch) {
      self.submitted = None
      for entry in batch.entries {
        entry.plan.cancel()
        entry.ticket.release().unwrap()
      }
    }
    return CommitFencedResult("late-completion-after-fence")
  }
  match completion {
    @persistence.PolicyCapabilityReady => {
      if !self.policy_upgrade_pending || !self.writer.policy_required() {
        self.fenced = true
        return CommitFencedResult("policy-capability-completion")
      }
      self.policy_upgrade_pending = false
      return CommitPolicyCapabilityReady
    }
    @persistence.PolicyCapabilityFailed(reason) => {
      self.policy_upgrade_pending = false
      self.fenced = true
      return CommitFencedResult("policy-capability-" + reason)
    }
    @persistence.CheckpointPublished(lsn, generation) => {
      if lsn > self.last_released_lsn || generation < 1L {
        self.fenced = true
        return CommitFencedResult("checkpoint-completion-range")
      }
      return CommitCheckpointPublished(lsn, generation)
    }
    @persistence.CheckpointFailed(reason, fatal) => {
      if fatal {
        self.fenced = true
      }
      return CommitCheckpointFailed(reason, fatal)
    }
    _ => ()
  }
  let batch = match self.submitted {
    Some(value) => value
    None => {
      if completion is @persistence.Committed(epoch, first, last) &&
        epoch == self.writer_epoch &&
        first == self.last_batch_first_lsn &&
        last == self.last_batch_last_lsn &&
        first > 0L {
        return NoCommitCompletion
      }
      self.fenced = true
      return CommitFencedResult("unexpected-completion")
    }
  }
  self.submitted = None
  match completion {
    @persistence.Committed(epoch, first, last) if epoch == self.writer_epoch &&
      first == batch.first_lsn &&
      last == batch.last_lsn &&
      first == self.committed_lsn + 1L => {
      self.committed_lsn = last
      let prepared_results : Array[Array[@router.BrokerAction]] = []
      for entry in batch.entries {
        match entry.plan.commit() {
          Ok(value) => prepared_results.push(value)
          Err(_) => {
            for item in batch.entries {
              item.plan.cancel()
              item.ticket.release().unwrap()
            }
            self.fenced = true
            return CommitFencedResult("apply-after-fsync")
          }
        }
      }
      let actions : Array[RuntimeAction] = []
      let deltas : Array[@router.DurableDelta] = []
      let connections : Array[ConnectionId?] = []
      for index in 0..<batch.entries.length() {
        let entry = batch.entries[index]
        actions.append((entry.after_commit)(prepared_results[index]))
        deltas.push(entry.delta)
        connections.push(entry.connection_id)
        entry.ticket.release().unwrap()
        self.last_released_lsn = entry.lsn
      }
      self.last_batch_first_lsn = batch.first_lsn
      self.last_batch_last_lsn = batch.last_lsn
      CommitReleased(actions, deltas, connections)
    }
    @persistence.Failed(epoch, reason) if epoch == self.writer_epoch => {
      for entry in batch.entries {
        entry.plan.cancel()
        entry.ticket.release().unwrap()
      }
      self.fenced = true
      CommitFencedResult(reason)
    }
    _ => {
      for entry in batch.entries {
        entry.plan.cancel()
        entry.ticket.release().unwrap()
      }
      self.fenced = true
      CommitFencedResult("completion-range-mismatch")
    }
  }
}
