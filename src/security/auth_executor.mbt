///|
pub(all) enum AuthExecutorError {
  InvalidConfiguration
  BackendUnavailable
  AllocationFailure
} derive(Eq, Debug)

///|
pub(all) enum AuthSubmitResult {
  Submitted
  QueueFull
  ExecutorStopped
  SubmitRetryLater
  InvalidSubmission
  SubmissionAllocationFailure
} derive(Eq, Debug)

///|
pub(all) enum AuthCancelResult {
  CancelledBeforeRun
  CancelledWhileRunning
  CancelAlreadyCompleted
  CancelUnknown
  CancelRetryLater
} derive(Eq, Debug)

///|
pub(all) enum AuthCompletionOutcome {
  HashMatched
  HashMismatched
  AuthBackendUnavailable
  AuthInternalFailure
  AuthCancelledBeforeRun
  AuthFinishedAfterCancel
} derive(Eq, Debug)

///|
pub(all) struct AuthCompletion {
  task_id : Int64
  outcome : AuthCompletionOutcome
  verify_ns : Int64
} derive(Eq, Debug)

///|
pub(all) enum AuthPollResult {
  NoCompletion
  PollRetryLater
  PollInvalid
  Completion(AuthCompletion)
} derive(Eq, Debug)

///|
pub(all) enum AuthControlResult {
  ControlDone
  ControlRetryLater
  ControlInvalid
  ControlStillRunning
} derive(Eq, Debug)

///|
pub struct AuthExecutor {
  priv mut handle : Int64
}

///|
extern "C" fn auth_executor_initialize_ffi() -> Int = "moonbit_mqtt_auth_executor_initialize"

///|
extern "C" fn auth_executor_create_ffi(
  workers : Int,
  queue_limit : Int,
) -> Int64 = "moonbit_mqtt_auth_executor_create_ffi"

///|
#borrow(encoded, password)
extern "C" fn auth_executor_submit_ffi(
  handle : Int64,
  task_id : Int64,
  encoded : Bytes,
  encoded_length : Int,
  password : Bytes,
  password_length : Int,
) -> Int = "moonbit_mqtt_auth_executor_submit_ffi"

///|
extern "C" fn auth_executor_cancel_ffi(handle : Int64, task_id : Int64) -> Int = "moonbit_mqtt_auth_executor_cancel_ffi"

///|
extern "C" fn auth_executor_poll_id_ffi(handle : Int64) -> Int64 = "moonbit_mqtt_auth_executor_poll_id_ffi"

///|
extern "C" fn auth_executor_completion_result_ffi(
  handle : Int64,
  task_id : Int64,
) -> Int = "moonbit_mqtt_auth_executor_completion_result_ffi"

///|
extern "C" fn auth_executor_completion_ns_ffi(
  handle : Int64,
  task_id : Int64,
) -> Int64 = "moonbit_mqtt_auth_executor_completion_ns_ffi"

///|
extern "C" fn auth_executor_reap_ffi(handle : Int64, task_id : Int64) -> Int = "moonbit_mqtt_auth_executor_reap_ffi"

///|
extern "C" fn auth_executor_stop_ffi(handle : Int64) -> Int = "moonbit_mqtt_auth_executor_stop_ffi"

///|
extern "C" fn auth_executor_is_stopped_ffi(handle : Int64) -> Int = "moonbit_mqtt_auth_executor_is_stopped_ffi"

///|
extern "C" fn auth_executor_destroy_ffi(handle : Int64) -> Int = "moonbit_mqtt_auth_executor_destroy_ffi"

///|
pub fn AuthExecutor::new(
  workers : Int,
  queue_limit : Int,
) -> Result[AuthExecutor, AuthExecutorError] {
  if workers < 1 ||
    workers > 64 ||
    queue_limit < 0 ||
    queue_limit > 4096 - workers {
    return Err(InvalidConfiguration)
  }
  if auth_executor_initialize_ffi() != 0 {
    return Err(BackendUnavailable)
  }
  let handle = auth_executor_create_ffi(workers, queue_limit)
  if handle == 0L {
    Err(AllocationFailure)
  } else {
    Ok({ handle, })
  }
}

///|
pub fn AuthExecutor::submit(
  self : AuthExecutor,
  task_id : Int64,
  request : PasswordAuthentication,
) -> AuthSubmitResult {
  if self.handle == 0L {
    return ExecutorStopped
  }
  let encoded = @utf8.encode(request.entry.encoded)
  match
    auth_executor_submit_ffi(
      self.handle,
      task_id,
      encoded,
      encoded.length(),
      request.password,
      request.password.length(),
    ) {
    0 => Submitted
    1 => QueueFull
    2 => ExecutorStopped
    3 => SubmitRetryLater
    5 => SubmissionAllocationFailure
    _ => InvalidSubmission
  }
}

///|
pub fn AuthExecutor::cancel(
  self : AuthExecutor,
  task_id : Int64,
) -> AuthCancelResult {
  match auth_executor_cancel_ffi(self.handle, task_id) {
    0 => CancelledBeforeRun
    1 => CancelledWhileRunning
    2 => CancelAlreadyCompleted
    4 => CancelRetryLater
    _ => CancelUnknown
  }
}

///|
fn completion_outcome(code : Int) -> AuthCompletionOutcome? {
  match code {
    0 => Some(HashMatched)
    1 => Some(HashMismatched)
    2 => Some(AuthBackendUnavailable)
    3 => Some(AuthInternalFailure)
    4 => Some(AuthCancelledBeforeRun)
    5 => Some(AuthFinishedAfterCancel)
    _ => None
  }
}

///|
pub fn AuthExecutor::poll(self : AuthExecutor) -> AuthPollResult {
  let task_id = auth_executor_poll_id_ffi(self.handle)
  if task_id == 0L {
    return NoCompletion
  }
  if task_id == -1L {
    return PollRetryLater
  }
  if task_id < 0L {
    return PollInvalid
  }
  let result = auth_executor_completion_result_ffi(self.handle, task_id)
  if result == 103 {
    return PollRetryLater
  }
  let outcome = match completion_outcome(result) {
    Some(value) => value
    None => return PollInvalid
  }
  let verify_ns = auth_executor_completion_ns_ffi(self.handle, task_id)
  if verify_ns == -1L {
    return PollRetryLater
  }
  if verify_ns < 0L {
    return PollInvalid
  }
  Completion({ task_id, outcome, verify_ns })
}

///|
pub fn AuthExecutor::reap(
  self : AuthExecutor,
  task_id : Int64,
) -> AuthControlResult {
  match auth_executor_reap_ffi(self.handle, task_id) {
    0 => ControlDone
    3 => ControlRetryLater
    _ => ControlInvalid
  }
}

///|
pub fn AuthExecutor::stop(self : AuthExecutor) -> AuthControlResult {
  match auth_executor_stop_ffi(self.handle) {
    0 => ControlDone
    3 => ControlRetryLater
    _ => ControlInvalid
  }
}

///|
pub fn AuthExecutor::is_stopped(self : AuthExecutor) -> Bool? {
  match auth_executor_is_stopped_ffi(self.handle) {
    0 => Some(false)
    1 => Some(true)
    _ => None
  }
}

///|
pub fn AuthExecutor::destroy(self : AuthExecutor) -> AuthControlResult {
  if self.handle == 0L {
    return ControlDone
  }
  match auth_executor_destroy_ffi(self.handle) {
    0 => {
      self.handle = 0L
      ControlDone
    }
    2 => ControlStillRunning
    3 => ControlRetryLater
    _ => ControlInvalid
  }
}
