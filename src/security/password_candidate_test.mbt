///|
async fn stop_candidate_executor(executor : AuthExecutor) -> Unit {
  for _ in 0..<1000 {
    match executor.stop() {
      ControlDone => break
      ControlRetryLater => @async.sleep(1)
      _ => fail("maintenance executor stop failed")
    }
  }
  for _ in 0..<1000 {
    if executor.is_stopped() == Some(true) {
      assert_eq(executor.destroy(), ControlDone)
      return
    }
    @async.sleep(1)
  }
  fail("maintenance executor did not reap")
}

///|
async test "password candidate validates PHCs on an isolated executor" {
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  let executor = AuthExecutor::new(1, 0).unwrap()
  let bad = PasswordDatabaseCandidate::parse(
    "sensor01:$argon2id$v=19$m=4096,t=2,p=1$bad$bad",
  ).unwrap()
  let rejected = try {
    ignore(bad.validate_with(executor))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let candidate = PasswordDatabaseCandidate::parse("sensor01:" + encoded).unwrap()
  let database = candidate.validate_with(executor)
  assert_eq(database.user_count(), 1)
  assert_eq(
    database.authenticate("sensor01", b"correct horse"),
    AuthenticationResult::Authenticated(Principal::User("sensor01")),
  )
  stop_candidate_executor(executor)
}

///|
test "password candidate rejects excessive cost before worker submission" {
  assert_true(
    PasswordDatabaseCandidate::parse(
      "user:$argon2id$v=19$m=999999,t=10,p=4$bad$bad",
    )
    is Err(HashCostExceeded(_)),
  )
}

///|
async test "maintenance Argon2 validation leaves the async loop responsive" {
  let encoded = "$argon2id$v=19$m=65536,t=3,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  let candidate = PasswordDatabaseCandidate::parse("sensor01:" + encoded).unwrap()
  let executor = AuthExecutor::new(1, 0).unwrap()
  let mut ticks = 0
  let mut running = true
  @async.with_task_group() <| group => {
    let ticker = group.spawn(() => {
      while running {
        @async.sleep(1)
        ticks += 1
      }
    })
    let validated = candidate.validate_with(executor)
    assert_eq(validated.user_count(), 1)
    running = false
    ticker.wait()
  }
  assert_true(ticks > 0)
  stop_candidate_executor(executor)
}

///|
test "reload account cap is enforced before Argon2 work" {
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  let contents = "first:" + encoded + "\nsecond:" + encoded + "\n"
  assert_true(
    PasswordDatabaseCandidate::parse(contents, max_accounts=1)
    is Err(AccountLimitExceeded),
  )
  assert_true(
    PasswordDatabaseCandidate::parse(contents, max_accounts=2) is Ok(_),
  )
}
