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

///|
test "runtime cleanup can discard a clean Session pending item" {
  let config = BrokerConfig::new(
    4,
    16,
    4,
    max_sessions=4,
    max_inflight_per_session=0,
    max_inflight_total=0,
    max_pending_per_session=2,
    max_pending_total=2,
  ).unwrap()
  let state = BrokerState::new(config)
  state.enable_policy_index().unwrap()
  let client = @session.ClientId::new("clean").unwrap()
  ignore(state.apply(CreateSession(client)).unwrap())
  ignore(
    state
    .apply(
      Subscribe({
        client_id: client,
        entries: [
          {
            filter: @topic.TopicFilter::new("private/#").unwrap(),
            qos: @session.QoS1,
          },
        ],
      }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("private/value").unwrap(),
        payload: b"x",
        qos: @session.QoS1,
        retain: false,
      }),
    )
    .unwrap(),
  )
  assert_eq(state.pending_qos1_count(), 1)
  let acl = @security.AclPolicy::parse("").unwrap()
  assert_true(state.set_security_policy(@security.SecurityPolicy::new(acl~)))
  let before = state.snapshot_revision()
  let plan = state
    .prepare_durable_reconcile(
      client,
      DropPendingHead("private/value", 1, 1),
      1L,
      require_persistent=false,
    )
    .unwrap()
  state.begin_action_scope()
  assert_eq(plan.commit(), Ok([]))
  state.end_action_scope()
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(state.snapshot_revision(), before)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "policy discard near reload queue cap copies only bounded message references" {
  let pending : Array[SnapshotMessageV3] = []
  for index in 0..<4096 {
    pending.push({
      topic: if index == 2048 {
        "private/one"
      } else {
        "safe/one"
      },
      payload: b"x",
      qos: 1,
      retain: false,
    })
  }
  let config = BrokerConfig::new(
    4,
    16,
    4,
    max_sessions=1,
    max_pending_per_session=4096,
    max_pending_total=4096,
  ).unwrap()
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
        pending,
      },
    ],
    retained: [],
  }
  let state = BrokerState::from_snapshot(config, snapshot).unwrap()
  state.enable_policy_index().unwrap()
  let acl = @security.AclPolicy::parse("anonymous\ntopic read safe/#\n").unwrap()
  assert_true(state.set_security_policy(@security.SecurityPolicy::new(acl~)))
  let client = @session.ClientId::new("large").unwrap()
  let plan = state
    .prepare_durable_reconcile(
      client,
      DropPendingAt(2048, "private/one", 1, 1),
      1L,
    )
    .unwrap()
  assert_eq(state.pending_qos1_count(), 4096)
  state.begin_action_scope()
  assert_eq(plan.commit(), Ok([]))
  state.end_action_scope()
  assert_eq(state.pending_qos1_count(), 4095)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "prepared policy discard rejects a changed Session queue" {
  let config = BrokerConfig::new(
    4,
    16,
    4,
    max_sessions=1,
    max_pending_per_session=4,
    max_pending_total=4,
  ).unwrap()
  let snapshot : BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "changed",
        owner_principal: "anonymous",
        detached_at_ms: 0L,
        next_packet_id: 1,
        subscriptions: [{ filter: "safe/#", qos: 1 }],
        inbound_qos2: [],
        inflight: [],
        pending: [
          { topic: "private/one", payload: b"x", qos: 1, retain: false },
        ],
      },
    ],
    retained: [],
  }
  let state = BrokerState::from_snapshot(config, snapshot).unwrap()
  state.enable_policy_index().unwrap()
  let policy = @security.SecurityPolicy::new(
    acl=@security.AclPolicy::parse("anonymous\ntopic read safe/#\n").unwrap(),
  )
  assert_true(state.set_security_policy(policy))
  let client = @session.ClientId::new("changed").unwrap()
  let plan = state
    .prepare_durable_reconcile(
      client,
      DropPendingAt(0, "private/one", 1, 1),
      1L,
    )
    .unwrap()
  ignore(
    state
    .apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("safe/two").unwrap(),
        payload: b"y",
        qos: @session.QoS1,
        retain: false,
      }),
    )
    .unwrap(),
  )
  state.begin_action_scope()
  assert_true(plan.commit() is Err(_))
  state.end_action_scope()
  plan.cancel()
  assert_eq(state.pending_qos1_count(), 2)
  assert_eq(state.check_invariants(), Ok(()))
}
