///|
test "durable unsubscribe keeps subscription until committed" {
  let state = BrokerState::new(BrokerConfig::new(4, 16, 4).unwrap())
  let client = @session.ClientId::new("subscriber").unwrap()
  let filter = @topic.TopicFilter::new("state/#").unwrap()
  let missing = @topic.TopicFilter::new("other/#").unwrap()
  ignore(
    state.apply(
      CreateSessionWith({
        client_id: client,
        mode: @session.Persistent,
        attached: true,
      }),
    ),
  )
  ignore(
    state.apply(
      Subscribe({ client_id: client, entries: [{ filter, qos: @session.QoS1 }] }),
    ),
  )
  let before = state.export_snapshot()
  let occupied = state.resource_ledger().occupied()
  let plan = state
    .prepare_durable_unsubscribe(client, [filter, missing, filter], 7L)
    .unwrap()
  assert_eq(state.subscription_qos(client, filter), Some(@session.QoS1))
  assert_eq(state.export_snapshot(), before)
  assert_eq(plan.delta().session_puts[0].session.subscriptions, [])
  plan.cancel()
  assert_eq(state.resource_ledger().occupied(), occupied)
  let plan = state
    .prepare_durable_unsubscribe(client, [filter, missing, filter], 7L)
    .unwrap()
  let accumulator = DurableAccumulator::new(state.config(), before, [7L]).unwrap()
  assert_eq(accumulator.apply(plan.delta()), Ok(()))
  let actions = plan.commit().unwrap()
  assert_eq(actions, [
    UnsubscriptionsApplied({ client_id: client, removed: [true, false, false] }),
  ])
  assert_eq(state.subscription_qos(client, filter), None)
  assert_eq(accumulator.export_snapshot().0, state.export_snapshot())
  assert_eq(state.check_invariants(), Ok(()))
}
