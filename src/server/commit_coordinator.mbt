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
  CommitReleased(Array[RuntimeAction], @router.DurableDelta)
  CommitFencedResult(String)
  CommitCheckpointPublished(Int64, Int64)
  CommitCheckpointFailed(String, Bool)
}

///|
pub struct PendingCommit {
  lsn : Int64
  plan : PreparedBrokerMutation
  delta : @router.DurableDelta
  after_commit : (Array[@router.BrokerAction]) -> Array[RuntimeAction]
  ticket : @budget.Ticket
  pending_bytes : Int64
}

///|
pub struct CommitCoordinator {
  writer : @persistence.WalWriter
  pool : @budget.Pool
  max_delta_bytes : Int
  writer_epoch : Int64
  mut committed_lsn : Int64
  mut last_released_lsn : Int64
  mut pending : PendingCommit?
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
    max_delta_bytes,
    writer_epoch,
    committed_lsn,
    last_released_lsn: committed_lsn,
    pending: None,
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
pub fn CommitCoordinator::is_fenced(self : CommitCoordinator) -> Bool {
  self.fenced || self.writer.is_fenced()
}

///|
pub fn CommitCoordinator::has_pending(self : CommitCoordinator) -> Bool {
  self.pending is Some(_)
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
pub fn CommitCoordinator::pending_bytes(self : CommitCoordinator) -> Int64 {
  self.pending.map(item => item.pending_bytes).unwrap_or(0L)
}

///|
pub fn CommitCoordinator::submit(
  self : CommitCoordinator,
  plan : PreparedBrokerMutation,
  after_commit : (Array[@router.BrokerAction]) -> Array[RuntimeAction],
) -> Result[Int64, CommitSubmitError] {
  if self.is_fenced() {
    plan.cancel()
    return Err(CommitFenced)
  }
  if self.pending is Some(_) {
    plan.cancel()
    return Err(CommitBusy)
  }
  if self.committed_lsn == 9223372036854775807L {
    plan.cancel()
    self.fenced = true
    return Err(CommitLsnExhausted)
  }
  let delta = plan.delta()
  let encoded = match
    @persistence.encode_durable_delta(delta, max_bytes=self.max_delta_bytes) {
    Ok(value) => value
    Err(_) => {
      plan.cancel()
      return Err(CommitEncoding)
    }
  }
  let ticket = match self.pool.reserve(encoded.length().to_int64() + 128L) {
    Ok(value) => value
    Err(_) => {
      plan.cancel()
      return Err(CommitBudget)
    }
  }
  let lsn = self.committed_lsn + 1L
  let batch : @persistence.WalBatch = {
    previous_lsn: self.committed_lsn,
    transactions: [{ lsn, delta: encoded }],
  }
  if !self.writer.submit({ writer_epoch: self.writer_epoch, batch }) {
    ticket.release().unwrap()
    plan.cancel()
    self.fenced = true
    return Err(CommitWriterUnavailable)
  }
  self.pending = Some({
    lsn,
    plan,
    delta,
    after_commit,
    ticket,
    pending_bytes: encoded.length().to_int64() + 128L,
  })
  Ok(lsn)
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
  let completion = match self.writer.poll() {
    Some(value) => value
    None => return NoCommitCompletion
  }
  match completion {
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
  let pending = match self.pending {
    Some(value) => value
    None => {
      if completion is @persistence.Committed(_, first, last) &&
        first == last &&
        last == self.last_released_lsn {
        return NoCommitCompletion
      }
      self.fenced = true
      return CommitFencedResult("unexpected-completion")
    }
  }
  self.pending = None
  match completion {
    @persistence.Committed(epoch, first, last) if epoch == self.writer_epoch &&
      first == pending.lsn &&
      last == pending.lsn &&
      pending.lsn == self.committed_lsn + 1L => {
      self.committed_lsn = pending.lsn
      let actions = match pending.plan.commit() {
        Ok(value) => value
        Err(_) => {
          pending.ticket.release().unwrap()
          self.fenced = true
          return CommitFencedResult("apply-after-fsync")
        }
      }
      let released = (pending.after_commit)(actions)
      self.last_released_lsn = pending.lsn
      pending.ticket.release().unwrap()
      CommitReleased(released, pending.delta)
    }
    @persistence.Failed(epoch, reason) if epoch == self.writer_epoch => {
      pending.plan.cancel()
      pending.ticket.release().unwrap()
      self.fenced = true
      CommitFencedResult(reason)
    }
    _ => {
      pending.plan.cancel()
      pending.ticket.release().unwrap()
      self.fenced = true
      CommitFencedResult("completion-range-mismatch")
    }
  }
}
