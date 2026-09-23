///|
fn durable_lifecycle_fixture() -> (BrokerState, @session.ClientId) {
  let state = BrokerState::new(BrokerConfig::new(4, 16, 4).unwrap())
  let client = @session.ClientId::new("persistent").unwrap()
  ignore(
    state.apply(
      CreateSessionWith({
        client_id: client,
        mode: @session.SessionMode::Persistent,
        attached: true,
      }),
    ),
  )
  ignore(
    state.apply(
      Subscribe({
        client_id: client,
        entries: [
          {
            filter: @topic.TopicFilter::new("topic/#").unwrap(),
            qos: @session.DeliveryQoS::QoS1,
          },
        ],
      }),
    ),
  )
  (state, client)
}

///|
test "durable detach waits for commit before publishing detached state" {
  let (state, client) = durable_lifecycle_fixture()
  let before = state.export_snapshot()
  let prepared = state
    .prepare_durable_lifecycle(client, 3L, DetachAt(123L))
    .unwrap()
  assert_eq(state.export_snapshot(), before)
  assert_eq(state.session_attached(client), Some(true))
  assert_eq(prepared.delta().session_puts[0].generation, 3L)
  assert_eq(prepared.commit(), Ok([SessionDetached(client)]))
  assert_eq(state.session_attached(client), Some(false))
  assert_eq(state.session_detached_at_ms(client), Some(123L))
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "durable delete releases state only after commit and cancel preserves it" {
  let (state, client) = durable_lifecycle_fixture()
  let before = state.export_snapshot()
  let occupied = state.resource_ledger().occupied()
  let prepared = state.prepare_durable_lifecycle(client, 3L, Delete).unwrap()
  assert_eq(state.export_snapshot(), before)
  prepared.cancel()
  assert_eq(state.resource_ledger().occupied(), occupied)
  let prepared = state.prepare_durable_lifecycle(client, 3L, Delete).unwrap()
  assert_eq(prepared.delta().session_deletes[0].expected_generation, 3L)
  assert_eq(prepared.commit(), Ok([SessionRemoved(client)]))
  assert_eq(state.session_count(), 0)
  assert_eq(state.subscription_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}
