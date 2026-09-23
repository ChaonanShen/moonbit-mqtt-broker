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
} derive(Eq, Debug)

///|
pub(all) enum WalWork {
  WriteBatch(WalSubmission)
  WriteCheckpoint(WalCheckpoint)
}

///|
pub struct WalWriter {
  store : WalStore
  requests : @async.Queue[WalWork]
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
    let work = self.requests.get() catch { _ => break }
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
      WriteCheckpoint(checkpoint) => {
        let result = @async.protect_from_cancel(() => {
          self.store.publish_checkpoint(checkpoint)
        })
        match result {
          Ok(_) => CheckpointPublished(checkpoint.lsn, checkpoint.generation)
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
