///|
test "durable reconcile commits one denied filter and pending head" {
  let config = BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap()
  let snapshot : BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "client-a",
        owner_principal: "anonymous",
        detached_at_ms: 0L,
        next_packet_id: 1,
        subscriptions: [
          { filter: "private/#", qos: 1 },
          { filter: "safe/#", qos: 1 },
        ],
        inbound_qos2: [],
        inflight: [],
        pending: [
          { topic: "safe/value", payload: b"y", qos: 1, retain: false },
          { topic: "private/value", payload: b"x", qos: 1, retain: false },
        ],
      },
    ],
    retained: [],
  }
  let state = BrokerState::from_snapshot(config, snapshot).unwrap()
  state.enable_policy_index().unwrap()
  let acl = @security.AclPolicy::parse("anonymous\ntopic read safe/#\n").unwrap()
  assert_true(state.set_security_policy(@security.SecurityPolicy::new(acl~)))
  let client = @session.ClientId::new("client-a").unwrap()
  let accumulator = DurableAccumulator::new(config, snapshot, [1L]).unwrap()
  let sub = state
    .prepare_durable_reconcile(client, DropSubscription("private/#"), 1L)
    .unwrap()
  assert_eq(state.subscription_count(), 2)
  assert_eq(accumulator.apply_reconcile(sub.delta()), Ok(()))
  state.begin_action_scope()
  assert_eq(sub.commit(), Ok([]))
  state.end_action_scope()
  assert_eq(state.subscription_count(), 1)
  let pending = match
    state.prepare_durable_reconcile(
      client,
      DropPendingAt(1, "private/value", 1, 1),
      1L,
    ) {
    Ok(value) => value
    Err(InvariantViolation(message)) => fail("invariant: " + message)
    Err(ByteResourceLimit(_)) => fail("byte budget")
    Err(_) => fail("other reconcile preparation failure")
  }
  assert_eq(accumulator.apply_reconcile(pending.delta()), Ok(()))
  state.begin_action_scope()
  assert_eq(pending.commit(), Ok([]))
  state.end_action_scope()
  assert_eq(state.pending_qos1_count(), 1)
  assert_eq(state.export_snapshot().sessions[0].pending[0].topic, "safe/value")
  assert_eq(state.export_snapshot(), accumulator.export_snapshot().0)
  assert_eq(state.check_invariants(), Ok(()))
}
