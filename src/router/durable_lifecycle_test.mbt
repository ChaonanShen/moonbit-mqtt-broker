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

///|
test "durable eviction of a large queued Session needs only bounded scratch" {
  let resources = @budget.Limits::default()
    .with_value("max_routing_scratch_bytes", 4194304L)
    .unwrap()
  let config = BrokerConfig::new(4, 16, 4, max_sessions=4, resources~).unwrap()
  let payload = Bytes::make(3145728, b'x')
  let snapshot : BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "large",
        owner_principal: "anonymous",
        detached_at_ms: 0L,
        next_packet_id: 1,
        subscriptions: [],
        inbound_qos2: [],
        inflight: [],
        pending: [{ topic: "large/value", payload, qos: 1, retain: false }],
      },
    ],
    retained: [],
  }
  let state = BrokerState::from_snapshot(config, snapshot).unwrap()
  let client = @session.ClientId::new("large").unwrap()
  let plan = state.prepare_durable_lifecycle(client, 1L, Delete).unwrap()
  assert_eq(plan.delta().session_puts.length(), 0)
  assert_eq(plan.delta().session_deletes.length(), 1)
  state.begin_action_scope()
  ignore(plan.commit().unwrap())
  state.end_action_scope()
  assert_eq(state.session_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}
