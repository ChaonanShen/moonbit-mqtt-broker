///|
test "durable expiry initializes recovered timestamp then deletes on committed deadline" {
  let config = BrokerConfig::new(4, 16, 4, persistent_session_expiry_ms=100L).unwrap()
  let state = BrokerState::new(config)
  let client = @session.ClientId::new("offline").unwrap()
  ignore(
    state.apply(
      CreateSessionWith({
        client_id: client,
        mode: @session.Persistent,
        attached: false,
      }),
    ),
  )
  let first = state.next_durable_expiration(1000L).unwrap()
  assert_eq(first.0, client)
  assert_eq(first.1, SetDetachedAt(1000L))
  let plan = state.prepare_durable_lifecycle(client, 1L, first.1).unwrap()
  assert_eq(state.session_detached_at_ms(client), Some(0L))
  assert_eq(plan.commit(), Ok([SessionDetached(client)]))
  assert_eq(state.session_detached_at_ms(client), Some(1000L))
  assert_true(state.next_durable_expiration(1099L) is None)
  let due = state.next_durable_expiration(1100L).unwrap()
  assert_eq(due, (client, Delete))
  let plan = state.prepare_durable_lifecycle(client, 1L, due.1).unwrap()
  assert_true(state.has_session(client))
  assert_eq(plan.commit(), Ok([SessionRemoved(client)]))
  assert_false(state.has_session(client))
  assert_eq(state.check_invariants(), Ok(()))
}
