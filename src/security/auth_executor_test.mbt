///|
fn executor_test_database() -> PasswordDatabase {
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  PasswordDatabase::parse("sensor01:" + encoded).unwrap()
}

///|
fn submit_until_decided(
  executor : AuthExecutor,
  task_id : Int64,
  request : PasswordAuthentication,
) -> AuthSubmitResult raise {
  for _ in 0..<1000000 {
    match executor.submit(task_id, request) {
      SubmitRetryLater => continue
      result => return result
    }
  }
  fail("authentication submit did not leave RetryLater")
}

///|
fn wait_for_completion(executor : AuthExecutor) -> AuthCompletion raise {
  for _ in 0..<10000000 {
    match executor.poll() {
      NoCompletion | PollRetryLater => continue
      PollInvalid => fail("authentication poll failed")
      Completion(value) => return value
    }
  }
  fail("authentication completion timed out")
}

///|
fn reap_until_decided(
  executor : AuthExecutor,
  task_id : Int64,
) -> AuthControlResult raise {
  for _ in 0..<1000000 {
    match executor.reap(task_id) {
      ControlRetryLater => continue
      result => return result
    }
  }
  fail("authentication reap did not leave RetryLater")
}

///|
fn stop_until_decided(executor : AuthExecutor) -> AuthControlResult raise {
  for _ in 0..<1000000 {
    match executor.stop() {
      ControlRetryLater => continue
      result => return result
    }
  }
  fail("authentication stop did not leave RetryLater")
}

///|
test "native authentication executor returns bounded hash outcomes" {
  let executor = AuthExecutor::new(1, 1).unwrap()
  let database = executor_test_database()

  let correct = database.prepare_password("sensor01", b"correct horse").unwrap()
  let correct_candidate = correct.candidate()
  assert_eq(submit_until_decided(executor, 1L, correct), Submitted)
  let matched = wait_for_completion(executor)
  assert_eq(matched.task_id, 1L)
  assert_eq(matched.outcome, AuthCompletionOutcome::HashMatched)
  assert_true(matched.verify_ns > 0L)
  assert_eq(
    correct_candidate.complete_connect(true),
    ConnectAuthentication::Accepted(Principal::User("sensor01")),
  )
  assert_eq(reap_until_decided(executor, 1L), ControlDone)

  let unknown = database.prepare_password("unknown", b"correct horse").unwrap()
  let unknown_candidate = unknown.candidate()
  assert_eq(submit_until_decided(executor, 2L, unknown), Submitted)
  let fallback_match = wait_for_completion(executor)
  assert_eq(fallback_match.task_id, 2L)
  assert_eq(fallback_match.outcome, AuthCompletionOutcome::HashMatched)
  assert_eq(
    unknown_candidate.complete_connect(true),
    ConnectAuthentication::BadCredentials,
  )
  assert_eq(reap_until_decided(executor, 2L), ControlDone)

  let wrong = database.prepare_password("sensor01", b"wrong").unwrap()
  assert_eq(submit_until_decided(executor, 3L, wrong), Submitted)
  let mismatched = wait_for_completion(executor)
  assert_eq(mismatched.task_id, 3L)
  assert_eq(mismatched.outcome, AuthCompletionOutcome::HashMismatched)
  assert_eq(reap_until_decided(executor, 3L), ControlDone)

  assert_eq(stop_until_decided(executor), ControlDone)
  for _ in 0..<10000000 {
    match executor.is_stopped() {
      Some(true) => break
      _ => continue
    }
  }
  assert_eq(executor.is_stopped(), Some(true))
  assert_eq(executor.destroy(), ControlDone)
  assert_eq(executor.destroy(), ControlDone)
}
