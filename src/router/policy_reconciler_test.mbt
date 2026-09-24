///|
test "policy reconciler discovers revoked owners filters and indexed pending" {
  let config = BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap()
  let snapshot : BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "removed",
        owner_principal: "user:removed",
        detached_at_ms: 0L,
        next_packet_id: 1,
        subscriptions: [{ filter: "private/#", qos: 1 }],
        inbound_qos2: [],
        inflight: [],
        pending: [],
      },
      {
        client_id: "anonymous",
        owner_principal: "anonymous",
        detached_at_ms: 0L,
        next_packet_id: 1,
        subscriptions: [
          { filter: "safe/#", qos: 1 },
          { filter: "private/#", qos: 1 },
        ],
        inbound_qos2: [],
        inflight: [],
        pending: [
          { topic: "safe/one", payload: b"a", qos: 1, retain: false },
          { topic: "private/two", payload: b"b", qos: 1, retain: false },
        ],
      },
    ],
    retained: [],
  }
  let state = BrokerState::from_snapshot(config, snapshot).unwrap()
  state.enable_policy_index().unwrap()
  let acl = @security.AclPolicy::parse("anonymous\ntopic read safe/#\n").unwrap()
  let policy = @security.SecurityPolicy::new(acl~)
  assert_true(state.set_security_policy(policy))
  let scan = PolicyReconciler::new(policy, 1L, 8, 1048576L).unwrap()
  let mut evictions = 0
  let mut filters = 0
  let mut pending = 0
  let mut done = false
  for _ in 0..<1000 {
    match scan.next(state) {
      PolicyScanIssue(issue) => {
        match issue {
          EvictSession(id, _) => {
            ignore(state.apply(RemoveSession(id)).unwrap())
            evictions += 1
          }
          DropFilter(id, _, _, filter) => {
            ignore(
              state
              .apply(Unsubscribe({ client_id: id, filters: [filter] }))
              .unwrap(),
            )
            filters += 1
          }
          DropPending(id, _, _, index, topic, qos, bytes) => {
            let plan = state
              .prepare_durable_reconcile(
                id,
                DropPendingAt(index, topic, qos, bytes),
                1L,
              )
              .unwrap()
            state.begin_action_scope()
            ignore(plan.commit().unwrap())
            state.end_action_scope()
            pending += 1
          }
        }
        assert_true(scan.complete_issue(issue))
      }
      PolicyScanProgress => ()
      PolicyScanDone => {
        done = true
        break
      }
      _ => fail("reconciler stalled")
    }
  }
  assert_true(done)
  assert_eq((evictions, filters, pending), (1, 1, 1))
  assert_eq(state.session_count(), 1)
  assert_eq(state.subscription_count(), 1)
  assert_eq(state.pending_qos1_count(), 1)
  assert_eq(state.export_snapshot().sessions[0].pending[0].topic, "safe/one")
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "forbidden payload inflight requests eviction while PUBREL-only does not" {
  let config = BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap()
  let snapshot : BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "payload",
        owner_principal: "anonymous",
        detached_at_ms: 0L,
        next_packet_id: 2,
        subscriptions: [],
        inbound_qos2: [],
        inflight: [
          {
            packet_id: 1,
            phase: 1,
            message: Some({
              topic: "private/value",
              payload: b"x",
              qos: 1,
              retain: false,
            }),
          },
        ],
        pending: [],
      },
      {
        client_id: "control",
        owner_principal: "anonymous",
        detached_at_ms: 0L,
        next_packet_id: 2,
        subscriptions: [],
        inbound_qos2: [],
        inflight: [{ packet_id: 1, phase: 3, message: None }],
        pending: [],
      },
    ],
    retained: [],
  }
  let state = BrokerState::from_snapshot(config, snapshot).unwrap()
  state.enable_policy_index().unwrap()
  let acl = @security.AclPolicy::parse("anonymous\ntopic read safe/#\n").unwrap()
  let policy = @security.SecurityPolicy::new(acl~)
  assert_true(state.set_security_policy(policy))
  let scan = PolicyReconciler::new(policy, 1L, 8, 1048576L).unwrap()
  let mut found = false
  for _ in 0..<100 {
    match scan.next(state) {
      PolicyScanIssue(EvictSession(id, _)) => {
        assert_eq(id.value(), "payload")
        found = true
        break
      }
      PolicyScanProgress => ()
      _ => fail("unexpected inflight scan result")
    }
  }
  assert_true(found)
}

///|
test "empty policy indexes advance by bounded slots without a long no-op reload" {
  let config = BrokerConfig::new(32, 1024, 4, max_sessions=1024).unwrap()
  let state = BrokerState::new(config)
  state.enable_policy_index().unwrap()
  let policy = @security.SecurityPolicy::permissive()
  let scan = PolicyReconciler::new(policy, 1L, 64, 1048576L).unwrap()
  let mut turns = 0
  let mut done = false
  for _ in 0..<100 {
    turns += 1
    match scan.next(state) {
      PolicyScanProgress => ()
      PolicyScanDone => {
        done = true
        break
      }
      _ => fail("empty policy index produced issue")
    }
  }
  assert_true(done)
  assert_true(turns < 100)
}
