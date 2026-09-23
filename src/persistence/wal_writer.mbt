///|
pub(all) struct WalSubmission {
  writer_epoch : Int64
  batch : WalBatch
}

///|
pub(all) enum WalCompletion {
  Committed(Int64, Int64, Int64)
  Failed(Int64, String)
} derive(Eq, Debug)

///|
pub struct WalWriter {
  store : WalStore
  requests : @async.Queue[WalSubmission]
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
  self.requests.try_put(submission) catch {
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
    let submission = self.requests.get() catch { _ => break }
    let first = submission.batch.previous_lsn + 1L
    let last = submission.batch.transactions[submission.batch.transactions.length() -
      1].lsn
    let result = @async.protect_from_cancel(() => {
      self.store.append_batch(submission.batch)
    })
    let completion = match result {
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
