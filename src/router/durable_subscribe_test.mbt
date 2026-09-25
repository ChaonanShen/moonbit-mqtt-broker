///|
fn durable_subscribe_fixture() -> (BrokerState, @session.ClientId) {
  let state = BrokerState::new(
    BrokerConfig::new(
      4,
      16,
      4,
      max_inflight_per_session=2,
      max_inflight_total=4,
    ).unwrap(),
  )
  ignore(
    state.apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("state/value").unwrap(),
        payload: b"saved",
        qos: @session.DeliveryQoS::QoS1,
        retain: true,
      }),
    ),
  )
  let client = @session.ClientId::new("subscriber").unwrap()
  ignore(
    state.apply(
      CreateSessionWith({
        client_id: client,
        mode: @session.Persistent,
        attached: true,
      }),
    ),
  )
  (state, client)
}

///|
test "durable subscribe holds filter and retained replay until commit" {
  let (state, client) = durable_subscribe_fixture()
  let filter = @topic.TopicFilter::new("state/#").unwrap()
  let before = state.export_snapshot()
  let occupied = state.resource_ledger().occupied()
  let plan = state
    .prepare_durable_subscribe(client, [{ filter, qos: @session.QoS1 }], 4L)
    .unwrap()
  assert_eq(state.export_snapshot(), before)
  assert_eq(state.subscription_qos(client, filter), None)
  assert_eq(state.inflight_count(), 0)
  assert_eq(plan.delta().session_puts.length(), 1)
  plan.cancel()
  assert_eq(state.resource_ledger().occupied(), occupied)
  let plan = state
    .prepare_durable_subscribe(client, [{ filter, qos: @session.QoS1 }], 4L)
    .unwrap()
  let accumulator = DurableAccumulator::new(state.config(), before, [4L]).unwrap()
  assert_eq(accumulator.apply(plan.delta()), Ok(()))
  state.begin_action_scope()
  let actions = plan.commit().unwrap()
  state.end_action_scope()
  assert_true(actions[0] is SubscriptionsApplied(_))
  assert_true(actions[1] is Deliver(_))
  assert_eq(state.subscription_qos(client, filter), Some(@session.QoS1))
  assert_eq(state.inflight_count(), 1)
  assert_eq(accumulator.export_snapshot().0, state.export_snapshot())
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "C-T31 V5 durable subscribe delta keeps SID floor and replay identity" {
  let (state, client) = durable_subscribe_fixture()
  let before = state.export_snapshot_v5(100L, 1000L).unwrap()
  let filter = @topic.TopicFilter::new("state/#").unwrap()
  let plan = state
    .prepare_durable_subscribe(client, [{ filter, qos: @session.QoS1 }], 4L)
    .unwrap()
  let delta = plan.delta_v5(100L, 1000L).unwrap()
  assert_eq(delta.session_puts.length(), 1)
  assert_true(delta.id_floors.any(value => value.kind == 2))
  assert_true(delta.id_floors.any(value => value.kind == 3))
  let accumulator = DurableAccumulatorV5::new(before)
  assert_eq(accumulator.apply(delta), Ok(()))
  assert_eq(accumulator.snapshot().sessions[0].subscriptions.length(), 1)
  plan.cancel()
}
