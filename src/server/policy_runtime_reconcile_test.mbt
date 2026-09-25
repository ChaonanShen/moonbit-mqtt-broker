///|
test "runtime policy reconciliation removes only revoked Session material" {
  let broker_config = @router.BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap()
  let snapshot : @router.BrokerSnapshotV3 = {
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
  let state = @router.BrokerState::from_snapshot(broker_config, snapshot).unwrap()
  state.enable_policy_index().unwrap()
  let acl = @security.AclPolicy::parse("anonymous\ntopic read safe/#\n").unwrap()
  let policy = @security.SecurityPolicy::new(acl~)
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let runtime = BrokerRuntime::new(config, state, security=policy)
  let scan = @router.PolicyReconciler::new(policy, 1L, 8, 1048576L).unwrap()
  let mut completed = false
  for _ in 0..<1000 {
    match scan.next(state) {
      @router.PolicyScanIssue(issue) =>
        match runtime.apply_policy_issue_runtime(issue) {
          PolicyApplied(_) | PolicyStale =>
            assert_true(scan.complete_issue(issue))
          PolicyFailed => fail("runtime policy cleanup failed")
        }
      @router.PolicyScanProgress => ()
      @router.PolicyScanDone => {
        completed = true
        break
      }
      _ => fail("policy scan unavailable")
    }
  }
  assert_true(completed)
  assert_eq(state.session_count(), 1)
  assert_eq(state.subscription_count(), 1)
  assert_eq(state.pending_qos1_count(), 1)
  assert_eq(state.export_snapshot().sessions[0].pending[0].topic, "safe/one")
  assert_eq(state.check_invariants(), Ok(()))
  assert_eq(runtime.check_invariants(), Ok(()))
}
