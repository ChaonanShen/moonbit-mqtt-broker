///|
test "core policy index remains available and stable without management" {
  let state = BrokerState::new(
    BrokerConfig::new(2, 4, 0, max_sessions=4).unwrap(),
  )
  assert_eq(state.policy_session_page(0, 4), None)
  state.enable_policy_index().unwrap()
  let a = @session.ClientId::new("a").unwrap()
  let b = @session.ClientId::new("b").unwrap()
  let c = @session.ClientId::new("c").unwrap()
  for id in [a, b, c] {
    ignore(state.apply(CreateSession(id)))
  }
  let first = state.policy_session_page(0, 2).unwrap()
  assert_eq(first.keys, ["a", "b"])
  assert_eq(first.scanned, 2)
  assert_true(first.has_more)
  ignore(state.apply(RemoveSession(b)))
  let d = @session.ClientId::new("d").unwrap()
  ignore(state.apply(CreateSession(d)))
  let after = state.policy_session_page(0, 4).unwrap()
  assert_eq(after.keys, ["a", "d", "c"])
  assert_eq(state.session_count(), 3)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "core policy gate rejects a newly forbidden owner" {
  let state = BrokerState::new(
    BrokerConfig::new(2, 4, 0, max_sessions=4).unwrap(),
  )
  state.enable_policy_index().unwrap()
  assert_true(
    state.set_security_policy(
      @security.SecurityPolicy::new(allow_anonymous=false),
    ),
  )
  let anonymous = @session.ClientId::new("anonymous").unwrap()
  assert_true(state.apply(CreateSession(anonymous)) is Err(_))
  assert_eq(state.session_count(), 0)
  assert_eq(state.policy_session_page(0, 4).unwrap().keys, [])
}
