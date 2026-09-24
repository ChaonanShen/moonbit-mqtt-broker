///|
pub(all) suberror PasswordCandidateError {
  ValidationBackendUnavailable
  ValidationInvalidHash
} derive(Eq, Debug)

///|
async fn reap_validation(executor : AuthExecutor, task_id : Int64) -> Unit {
  for ;; {
    match executor.reap(task_id) {
      ControlDone => return
      ControlRetryLater => @async.sleep(1)
      _ => abort("password validation worker lost task ownership")
    }
  }
}

///|
/// Runs the expensive PHC validation only on a caller-owned maintenance
/// executor. The executor must be independent of online authentication slots.
pub async fn PasswordDatabaseCandidate::validate_with(
  self : PasswordDatabaseCandidate,
  executor : AuthExecutor,
) -> PasswordDatabase {
  let mut task_id = 1L
  for username, _ in self.database.hashes {
    let request = self.database.prepare_password(username, b"").unwrap()
    for ;; {
      match executor.submit(task_id, request) {
        Submitted => break
        SubmitRetryLater | QueueFull => @async.sleep(1)
        _ => raise PasswordCandidateError::ValidationBackendUnavailable
      }
    }
    let mut active = true
    errdefer @async.protect_from_cancel(() => {
      if active {
        ignore(executor.cancel(task_id))
        for ;; {
          match executor.poll() {
            Completion(value) if value.task_id == task_id => {
              reap_validation(executor, task_id)
              break
            }
            _ => @async.sleep(1)
          }
        }
      }
    })
    let outcome = for ;; {
      match executor.poll() {
        Completion(value) if value.task_id == task_id => break value.outcome
        NoCompletion | PollRetryLater => @async.sleep(1)
        _ => raise PasswordCandidateError::ValidationBackendUnavailable
      }
    }
    reap_validation(executor, task_id)
    active = false
    match outcome {
      HashMatched | HashMismatched => ()
      AuthBackendUnavailable =>
        raise PasswordCandidateError::ValidationBackendUnavailable
      _ => raise PasswordCandidateError::ValidationInvalidHash
    }
    task_id += 1L
  }
  self.database
}
