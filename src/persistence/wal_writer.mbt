///|
pub(all) struct WalSubmission {
  writer_epoch : Int64
  batch : WalBatch
}

///|
pub(all) enum WalCompletion {
  Committed(Int64, Int64, Int64)
  Failed(Int64, String)
  CheckpointPublished(Int64, Int64)
  CheckpointFailed(String, Bool)
  PolicyCapabilityReady
  PolicyCapabilityFailed(String)
} derive(Eq, Debug)

///|
pub(all) enum WalWork {
  WriteBatch(WalSubmission)
  WriteCheckpoint(WalCheckpoint)
  WriteCheckpointV5(WalCheckpointV5)
  UpgradePolicyCapability
}

///|
pub struct WalWriter {
  store : WalStore
  requests : @async.Queue[WalWork]
  mut preempted_work : WalWork?
  mut checkpoint_active : Bool
  completions : @async.Queue[WalCompletion]
  mut closed : Bool
  mut stopped : Bool
  mut fenced : Bool
}

///|
pub fn WalWriter::new(store : WalStore) -> WalWriter {
  {
    store,
    requests: @async.Queue(kind=Blocking(1)),
    preempted_work: None,
    checkpoint_active: false,
    completions: @async.Queue(kind=Blocking(1)),
    closed: false,
    stopped: false,
    fenced: false,
  }
}

///|
/// A WAL submission is never replaced by a newer request.
pub fn WalWriter::submit(self : WalWriter, submission : WalSubmission) -> Bool {
  if self.closed ||
    self.fenced ||
    self.stopped ||
    submission.writer_epoch < 1L ||
    submission.batch.transactions.is_empty() {
    return false
  }
  self.requests.try_put(WriteBatch(submission)) catch {
    _ => false
  }
}

///|
pub fn WalWriter::submit_checkpoint(
  self : WalWriter,
  checkpoint : WalCheckpoint,
) -> Bool {
  if self.closed || self.fenced || self.stopped {
    return false
  }
  self.requests.try_put(WriteCheckpoint(checkpoint)) catch {
    _ => false
  }
}

///|
pub fn WalWriter::submit_checkpoint_v5(
  self : WalWriter,
  checkpoint : WalCheckpointV5,
) -> Bool {
  if self.closed || self.fenced || self.stopped {
    return false
  }
  self.requests.try_put(WriteCheckpointV5(checkpoint)) catch {
    _ => false
  }
}

///|
pub fn WalWriter::submit_policy_capability(self : WalWriter) -> Bool {
  if self.closed || self.fenced || self.stopped {
    return false
  }
  self.requests.try_put(UpgradePolicyCapability) catch {
    _ => false
  }
}

///|
pub fn WalWriter::policy_required(self : WalWriter) -> Bool {
  self.store.manifest().policy_required
}

///|
pub fn WalWriter::policy_state(self : WalWriter) -> WalPolicyState? {
  self.store.policy_state()
}

///|
pub fn WalWriter::poll(self : WalWriter) -> WalCompletion? {
  self.completions.try_get() catch {
    _ => None
  }
}

///|
pub fn WalWriter::committed_lsn(self : WalWriter) -> Int64 {
  self.store.committed_lsn()
}

///|
pub fn WalWriter::checkpoint_lsn(self : WalWriter) -> Int64 {
  self.store.manifest().checkpoint_lsn
}

///|
pub fn WalWriter::checkpoint_generation(self : WalWriter) -> Int64 {
  self.store.manifest().checkpoint_generation
}

///|
pub fn WalWriter::checkpoint_active(self : WalWriter) -> Bool {
  self.checkpoint_active
}

///|
pub fn WalWriter::is_fenced(self : WalWriter) -> Bool {
  self.fenced || self.store.is_fenced()
}

///|
pub fn WalWriter::close_requests(self : WalWriter) -> Unit {
  if !self.closed {
    self.closed = true
    self.requests.close(clear=false)
  }
}

///|
pub fn WalWriter::close_store(self : WalWriter) -> Unit {
  self.store.close()
  self.completions.close(clear=false)
}

///|
pub async fn WalWriter::run(self : WalWriter, wake : () -> Unit) -> Unit {
  for ;; {
    let work = match self.preempted_work {
      Some(value) => {
        self.preempted_work = None
        value
      }
      None => self.requests.get() catch { _ => break }
    }
    let completion = match work {
      WriteBatch(submission) => {
        let first = submission.batch.previous_lsn + 1L
        let last = submission.batch.transactions[submission.batch.transactions.length() -
          1].lsn
        let result = @async.protect_from_cancel(() => {
          self.store.append_batch(submission.batch)
        })
        match result {
          Ok(committed_lsn) if committed_lsn == last =>
            Committed(submission.writer_epoch, first, last)
          Ok(_) => {
            self.fenced = true
            Failed(submission.writer_epoch, "completion-range")
          }
          Err(error) => {
            self.fenced = true
            Failed(submission.writer_epoch, error.category())
          }
        }
      }
      UpgradePolicyCapability => {
        let result = @async.protect_from_cancel(() => {
          self.store.require_policy_capability()
        })
        match result {
          Ok(_) => PolicyCapabilityReady
          Err(error) => {
            self.fenced = true
            PolicyCapabilityFailed(error.category())
          }
        }
      }
      WriteCheckpoint(checkpoint) => {
        self.checkpoint_active = true
        wake()
        let result = @async.protect_from_cancel(() => {
          self.store.publish_checkpoint(checkpoint, preempt=() => {
            if self.preempted_work is Some(_) {
              return true
            }
            let queued = self.requests.try_get() catch { _ => None }
            match queued {
              Some(value) => {
                self.preempted_work = Some(value)
                true
              }
              None => false
            }
          })
        })
        self.checkpoint_active = false
        match result {
          Ok(_) => CheckpointPublished(checkpoint.lsn, checkpoint.generation)
          Err(FileSystem(operation="wal-checkpoint-preempted", ..)) =>
            CheckpointFailed("preempted", false)
          Err(error) => {
            if self.store.is_fenced() {
              self.fenced = true
            }
            CheckpointFailed(error.category(), self.fenced)
          }
        }
      }
      WriteCheckpointV5(checkpoint) => {
        self.checkpoint_active = true
        wake()
        let result = @async.protect_from_cancel(() => {
          self.store.publish_checkpoint_v5(checkpoint, preempt=() => {
            if self.preempted_work is Some(_) {
              return true
            }
            let queued = self.requests.try_get() catch { _ => None }
            match queued {
              Some(value) => {
                self.preempted_work = Some(value)
                true
              }
              None => false
            }
          })
        })
        self.checkpoint_active = false
        match result {
          Ok(_) => CheckpointPublished(checkpoint.lsn, checkpoint.generation)
          Err(FileSystem(operation="wal-checkpoint-preempted", ..)) =>
            CheckpointFailed("preempted", false)
          Err(error) => {
            if self.store.is_fenced() {
              self.fenced = true
            }
            CheckpointFailed(error.category(), self.fenced)
          }
        }
      }
    }
    self.completions.put(completion) catch {
      _ => break
    }
    wake()
    if self.fenced {
      break
    }
  }
  self.stopped = true
}

///|
pub fn WalWriter::uses_v5_schema(self : WalWriter) -> Bool {
  self.store.manifest_v5 is Some(_)
}
