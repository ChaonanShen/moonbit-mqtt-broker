///|
async test "strict coordinator releases activation only after WAL completion" {
  let path = "_build/server-commit-coordinator"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let persistence_config = @persistence.PersistenceConfig::new(path).unwrap()
  let lock = @persistence.SnapshotStore::open(persistence_config).unwrap()
  let checkpoint : @persistence.WalCheckpoint = {
    generation: 1L,
    lsn: 0L,
    identities: [],
    policy: None,
    snapshot: { version: 3, sessions: [], retained: [] },
  }
  let store = @persistence.WalStore::bootstrap(lock, checkpoint).unwrap()
  let writer = @persistence.WalWriter::new(store)
  let broker = @router.BrokerState::new(
    @router.BrokerConfig::new(4, 16, 4).unwrap(),
  )
  let coordinator = CommitCoordinator::new(
    writer,
    broker.resource_ledger(),
    33554432L,
    1048576,
    1L,
    0L,
  ).unwrap()
  let client = @session.ClientId::new("strict-client").unwrap()
  let activation = broker
    .prepare_durable_activation(
      client,
      @session.Persistent,
      @security.Principal::Anonymous,
      0L,
      1L,
    )
    .unwrap()
  assert_eq(coordinator.submit(Activation(activation), _ => []), Ok(1L))
  assert_eq(broker.session_count(), 0)
  let mut wakes = 0
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => wakes += 1))
    let mut completed = false
    for _ in 0..<1000 {
      match coordinator.poll() {
        CommitReleased(_, _, _) => {
          completed = true
          break
        }
        CommitFencedResult(reason) => fail("unexpected fence: " + reason)
        NoCommitCompletion => @async.sleep(1)
        _ => fail("unexpected checkpoint completion")
      }
    }
    assert_true(completed)
    assert_true(wakes > 0)
    assert_eq(coordinator.committed_lsn(), 1L)
    assert_eq(broker.session_count(), 1)
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
async test "timed-out WAL commit fences without ACK while restart may replay it" {
  let path = "_build/server-commit-timeout"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let broker = @router.BrokerState::new(broker_config)
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let store = @persistence.WalStore::bootstrap(lock, {
    generation: 1L,
    lsn: 0L,
    identities: [],
    policy: None,
    snapshot: { version: 3, sessions: [], retained: [] },
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
    commit_timeout_ms=10L,
  ).unwrap()
  let client = @session.ClientId::new("uncertain").unwrap()
  let activation = broker
    .prepare_durable_activation(
      client,
      @session.Persistent,
      @security.Principal::Anonymous,
      0L,
      1L,
    )
    .unwrap()
  assert_eq(coordinator.submit(Activation(activation), _ => []), Ok(1L))
  assert_true(coordinator.check_timeout(@async.now() + 10L))
  assert_true(coordinator.is_fenced())
  assert_eq(broker.session_count(), 0)
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    let mut observed = false
    for _ in 0..<1000 {
      if coordinator.poll() is CommitFencedResult(_) {
        observed = true
        break
      }
      @async.sleep(1)
    }
    assert_true(observed)
    assert_eq(broker.session_count(), 0)
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  let second = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let limits = @persistence.SnapshotDecodeLimits::new(broker_config, 1024).unwrap()
  let (recovered, replay) = @persistence.WalStore::recover_state(
    second, broker_config, limits,
  ).unwrap()
  assert_eq(replay.committed_lsn(), 1L)
  assert_true(replay.state().has_session(client))
  recovered.close()
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}

///|
async test "policy capability upgrade blocks business until durable writer completion" {
  let path = "_build/server-policy-capability"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let checkpoint : @persistence.WalCheckpoint = {
    generation: 1L,
    lsn: 0L,
    identities: [],
    policy: None,
    snapshot: { version: 3, sessions: [], retained: [] },
  }
  let store = @persistence.WalStore::bootstrap(lock, checkpoint).unwrap()
  let writer = @persistence.WalWriter::new(store)
  let broker = @router.BrokerState::new(
    @router.BrokerConfig::new(4, 16, 4).unwrap(),
  )
  let coordinator = CommitCoordinator::new(
    writer,
    broker.resource_ledger(),
    33554432L,
    1048576,
    1L,
    0L,
  ).unwrap()
  assert_true(coordinator.request_policy_capability())
  assert_true(coordinator.has_pending())
  assert_eq(coordinator.submit(Noop, _ => []), Err(CommitBusy))
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    let mut ready = false
    for _ in 0..<1000 {
      match coordinator.poll() {
        CommitPolicyCapabilityReady => {
          ready = true
          break
        }
        CommitFencedResult(reason) =>
          fail("unexpected policy upgrade fence: " + reason)
        NoCommitCompletion => @async.sleep(1)
        _ => fail("unexpected WAL completion")
      }
    }
    assert_true(ready)
    assert_false(coordinator.has_pending())
    assert_true(coordinator.policy_required())
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}

///|
async test "policy transition is a standalone durable commit before publication" {
  let path = "_build/server-policy-transition"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let broker = @router.BrokerState::new(broker_config)
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let store = @persistence.WalStore::bootstrap(lock, {
    generation: 1L,
    lsn: 0L,
    identities: [],
    policy: None,
    snapshot: { version: 3, sessions: [], retained: [] },
  }).unwrap()
  assert_eq(store.require_policy_capability(), Ok(()))
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
  let digest : Array[Byte] = []
  for _ in 0..<32 {
    digest.push(6)
  }
  let fingerprint = Bytes::from_array(digest)
  let mut published = false
  assert_eq(
    coordinator.submit(
      PolicyRecord({
        transition: @persistence.PolicyActivated,
        sequence: 1L,
        fingerprint,
      }),
      _ => {
        published = true
        []
      },
    ),
    Ok(1L),
  )
  assert_false(published)
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    let mut released = false
    for _ in 0..<1000 {
      match coordinator.poll() {
        CommitReleased(_, _, _) => {
          released = true
          break
        }
        CommitFencedResult(reason) => fail("policy commit fenced: " + reason)
        NoCommitCompletion => @async.sleep(1)
        _ => fail("unexpected policy commit result")
      }
    }
    assert_true(released)
    assert_true(published)
    assert_eq(
      coordinator.policy_state(),
      Some({ sequence: 1L, fingerprint, reconcile_pending: true }),
    )
    let checkpoint : @persistence.WalCheckpoint = {
      generation: 2L,
      lsn: 1L,
      identities: [],
      policy: coordinator.policy_state(),
      snapshot: { version: 3, sessions: [], retained: [] },
    }
    assert_true(coordinator.submit_checkpoint(checkpoint))
    let mut checkpointed = false
    for _ in 0..<1000 {
      match coordinator.poll() {
        CommitCheckpointPublished(1L, 2L) => {
          checkpointed = true
          break
        }
        CommitFencedResult(reason) =>
          fail("policy checkpoint fenced: " + reason)
        NoCommitCompletion => @async.sleep(1)
        _ => fail("unexpected policy checkpoint result")
      }
    }
    assert_true(checkpointed)
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}

///|
async test "strict local cleanup commits before changing retained Session state" {
  let path = "_build/server-policy-local-cleanup"
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
  assert_true(broker.set_security_policy(@security.SecurityPolicy::new(acl~)))
  let digest : Array[Byte] = []
  for _ in 0..<32 {
    digest.push(4)
  }
  let fingerprint = Bytes::from_array(digest)
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let store = @persistence.WalStore::bootstrap(lock, {
    generation: 1L,
    lsn: 0L,
    identities: [{ client_id: "client-a", generation: 1L }],
    policy: Some({ sequence: 1L, fingerprint, reconcile_pending: true }),
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
  let subscription = broker
    .prepare_durable_reconcile(
      client,
      @router.DropSubscription("private/#"),
      1L,
    )
    .unwrap()
  assert_eq(coordinator.submit(PolicyReconcile(subscription), _ => []), Ok(1L))
  assert_eq(broker.subscription_count(), 1)
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    let mut first = false
    for _ in 0..<1000 {
      match coordinator.poll() {
        CommitReleased(_, _, _) => {
          first = true
          break
        }
        CommitFencedResult(reason) => fail("policy cleanup fenced: " + reason)
        NoCommitCompletion => @async.sleep(1)
        _ => fail("unexpected cleanup completion")
      }
    }
    assert_true(first)
    assert_eq(broker.subscription_count(), 0)
    let pending = broker
      .prepare_durable_reconcile(
        client,
        @router.DropPendingHead("private/value", 1, 1),
        1L,
      )
      .unwrap()
    assert_eq(coordinator.submit(PolicyReconcile(pending), _ => []), Ok(2L))
    assert_eq(broker.pending_qos1_count(), 1)
    let mut second = false
    for _ in 0..<1000 {
      match coordinator.poll() {
        CommitReleased(_, _, _) => {
          second = true
          break
        }
        CommitFencedResult(reason) => fail("pending cleanup fenced: " + reason)
        NoCommitCompletion => @async.sleep(1)
        _ => fail("unexpected cleanup completion")
      }
    }
    assert_true(second)
    assert_eq(broker.pending_qos1_count(), 0)
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
  assert_eq(state.state().export_snapshot(), broker.export_snapshot())
  recovered.close()
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}
