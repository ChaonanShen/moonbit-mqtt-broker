///|
async test "strict policy issues use the existing WAL writer and completion" {
  let path = "_build/server-policy-issue-driver"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let broker_config = @router.BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap()
  let snapshot : @router.BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "client-a",
        owner_principal: "anonymous",
        detached_at_ms: 0L,
        next_packet_id: 1,
        subscriptions: [{ filter: "private/#", qos: 1 }],
        inbound_qos2: [],
        inflight: [],
        pending: [
          { topic: "private/value", payload: b"x", qos: 1, retain: false },
        ],
      },
    ],
    retained: [],
  }
  let broker = @router.BrokerState::from_snapshot(broker_config, snapshot).unwrap()
  broker.enable_policy_index().unwrap()
  let acl = @security.AclPolicy::parse("").unwrap()
  let policy = @security.SecurityPolicy::new(acl~)
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let runtime = BrokerRuntime::new(config, broker, security=policy)
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let digest : Array[Byte] = []
  for _ in 0..<32 {
    digest.push(8)
  }
  let store = @persistence.WalStore::bootstrap(lock, {
    generation: 1L,
    lsn: 0L,
    identities: [{ client_id: "client-a", generation: 1L }],
    policy: Some({
      sequence: 1L,
      fingerprint: Bytes::from_array(digest),
      reconcile_pending: true,
    }),
    snapshot,
  }).unwrap()
  let writer = @persistence.WalWriter::new(store)
  let coordinator = CommitCoordinator::new(
    writer,
    broker.resource_ledger(),
    33554432L,
    1048576,
    1L,
    0L,
    broker~,
  ).unwrap()
  let client = @session.ClientId::new("client-a").unwrap()
  let driver = RouterDriver::new(
    runtime,
    strict=coordinator,
    strict_generations=Map([(client, 1L)]),
  )
  let scan = @router.PolicyReconciler::new(policy, 1L, 8, 1048576L).unwrap()
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    let mut filter_issue : @router.PolicyIssue? = None
    for _ in 0..<1000 {
      match scan.next(broker) {
        @router.PolicyScanIssue(value) => {
          filter_issue = Some(value)
          break
        }
        @router.PolicyScanProgress => ()
        _ => fail("filter issue not discovered")
      }
    }
    let first = filter_issue.unwrap()
    assert_true(first is @router.DropFilter(_, _, _, _))
    assert_eq(
      driver.apply_policy_issue_strict(first, scan),
      PolicyIssueSubmitted,
    )
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      if coordinator.committed_lsn() == 1L {
        break
      }
      @async.sleep(1)
    }
    assert_eq(coordinator.committed_lsn(), 1L)
    assert_eq(broker.subscription_count(), 0)
    let mut pending_issue : @router.PolicyIssue? = None
    for _ in 0..<1000 {
      match scan.next(broker) {
        @router.PolicyScanIssue(value) => {
          pending_issue = Some(value)
          break
        }
        @router.PolicyScanProgress => ()
        _ => fail("pending issue not discovered")
      }
    }
    let second = pending_issue.unwrap()
    assert_true(second is @router.DropPending(_, _, _, _, _, _, _))
    assert_eq(
      driver.apply_policy_issue_strict(second, scan),
      PolicyIssueSubmitted,
    )
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      if coordinator.committed_lsn() == 2L {
        break
      }
      @async.sleep(1)
    }
    assert_eq(broker.pending_qos1_count(), 0)
    assert_eq(broker.check_invariants(), Ok(()))
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}

///|
async test "strict removed owner is evicted by a durable Session delete" {
  let path = "_build/server-policy-owner-eviction"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let broker_config = @router.BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap()
  let snapshot : @router.BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "deleted",
        owner_principal: "user:deleted",
        detached_at_ms: 0L,
        next_packet_id: 1,
        subscriptions: [],
        inbound_qos2: [],
        inflight: [],
        pending: [],
      },
    ],
    retained: [],
  }
  let broker = @router.BrokerState::from_snapshot(broker_config, snapshot).unwrap()
  broker.enable_policy_index().unwrap()
  let policy = @security.SecurityPolicy::permissive()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let runtime = BrokerRuntime::new(config, broker, security=policy)
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let digest : Array[Byte] = []
  for _ in 0..<32 {
    digest.push(9)
  }
  let store = @persistence.WalStore::bootstrap(lock, {
    generation: 1L,
    lsn: 0L,
    identities: [{ client_id: "deleted", generation: 1L }],
    policy: Some({
      sequence: 1L,
      fingerprint: Bytes::from_array(digest),
      reconcile_pending: true,
    }),
    snapshot,
  }).unwrap()
  let writer = @persistence.WalWriter::new(store)
  let coordinator = CommitCoordinator::new(
    writer,
    broker.resource_ledger(),
    33554432L,
    1048576,
    1L,
    0L,
    broker~,
  ).unwrap()
  let client = @session.ClientId::new("deleted").unwrap()
  let driver = RouterDriver::new(
    runtime,
    strict=coordinator,
    strict_generations=Map([(client, 1L)]),
  )
  let scan = @router.PolicyReconciler::new(policy, 1L, 8, 1048576L).unwrap()
  let issue = match scan.next(broker) {
    @router.PolicyScanIssue(value) => value
    _ => fail("deleted owner must be found immediately")
  }
  assert_true(issue is @router.EvictSession(_, _))
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    assert_eq(
      driver.apply_policy_issue_strict(issue, scan),
      PolicyIssueSubmitted,
    )
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      if coordinator.committed_lsn() == 1L {
        break
      }
      @async.sleep(1)
    }
    assert_eq(coordinator.committed_lsn(), 1L)
    assert_eq(broker.session_count(), 0)
    assert_eq(broker.check_invariants(), Ok(()))
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  let next = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let limits = @persistence.SnapshotDecodeLimits::new(broker_config, 1024).unwrap()
  let (recovered, state) = @persistence.WalStore::recover_state(
    next, broker_config, limits,
  ).unwrap()
  assert_eq(state.state().session_count(), 0)
  recovered.close()
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}
