///|
test "durable management delete keeps ETag target until committed" {
  let state = BrokerState::new(
    BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap(),
  )
  assert_true(state.enable_management_index())
  let client = @session.ClientId::new("durable-delete").unwrap()
  ignore(
    state
    .apply(
      CreateSessionWith({
        client_id: client,
        mode: @session.Persistent,
        attached: false,
      }),
    )
    .unwrap(),
  )
  let identity = state
    .management_index()
    .unwrap()
    .identity_for_client(client)
    .unwrap()
  assert_true(
    state.prepare_durable_admin_delete(
      identity.handle,
      identity.lifecycle_version + 1L,
      5L,
    )
    is Err(AdminPreconditionFailed),
  )
  let before = state.export_snapshot()
  let plan = state
    .prepare_durable_admin_delete(
      identity.handle,
      identity.lifecycle_version,
      5L,
    )
    .unwrap()
  assert_eq(state.export_snapshot(), before)
  assert_true(state.has_session(client))
  assert_eq(plan.delta().session_deletes[0].expected_generation, 5L)
  plan.cancel()
  let plan = state
    .prepare_durable_admin_delete(
      identity.handle,
      identity.lifecycle_version,
      5L,
    )
    .unwrap()
  assert_eq(plan.commit(), Ok([SessionRemoved(client)]))
  assert_false(state.has_session(client))
  assert_true(
    state.management_index().unwrap().identity_for_client(client) is None,
  )
  assert_eq(state.check_invariants(), Ok(()))
}
