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
  let old_b = state.policy_session_incarnation(b).unwrap()
  ignore(state.apply(RemoveSession(b)))
  let d = @session.ClientId::new("d").unwrap()
  ignore(state.apply(CreateSession(d)))
  assert_true(state.policy_session_incarnation(d).unwrap() > old_b)
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

///|
test "clean replacement advances core incarnation while restore keeps it" {
  let state = BrokerState::new(
    BrokerConfig::new(2, 4, 0, max_sessions=4).unwrap(),
  )
  state.enable_policy_index().unwrap()
  let id = @session.ClientId::new("same").unwrap()
  ignore(
    state.apply(
      CreateSessionWith({
        client_id: id,
        mode: @session.Persistent,
        attached: false,
      }),
    ),
  )
  let original = state.policy_session_incarnation(id).unwrap()
  let restore = state
    .prepare_activation(id, @session.Persistent, @security.Principal::Anonymous)
    .unwrap()
  ignore(state.commit_activation(restore).unwrap())
  assert_eq(state.policy_session_incarnation(id), Some(original))
  let clean = state
    .prepare_activation(id, @session.Clean, @security.Principal::Anonymous)
    .unwrap()
  ignore(state.commit_activation(clean).unwrap())
  assert_true(state.policy_session_incarnation(id).unwrap() > original)
  assert_eq(state.check_invariants(), Ok(()))
}
