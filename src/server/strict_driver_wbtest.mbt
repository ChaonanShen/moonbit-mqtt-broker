///|
async test "strict driver holds CONNECT state until its WAL completion" {
  let path = "_build/server-strict-driver"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let broker = @router.BrokerState::new(broker_config)
  let runtime = BrokerRuntime::new(config, broker)
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let writer = @persistence.WalWriter::new(
    @persistence.WalStore::bootstrap(lock, {
      generation: 1L,
      lsn: 0L,
      identities: [],
      snapshot: { version: 3, sessions: [], retained: [] },
    }).unwrap(),
  )
  let coordinator = CommitCoordinator::new(
    writer,
    broker.resource_ledger(),
    33554432L,
    1048576,
    1L,
    0L,
  ).unwrap()
  let driver = RouterDriver::new(runtime, strict=coordinator)
  let connection_id = ConnectionId::new(1L)
  driver.handle(Runtime(TransportOpened({ connection_id, accepted_at_ms: 0L })))
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id,
        received_at_ms: 1L,
        packet: Connect({
          client_id: "strict-driver-client",
          username: None,
          password: None,
          keep_alive: 10,
          clean_session: false,
          will: Some({
            topic: "will/topic",
            payload: b"offline",
            qos: QoS1,
            retain: true,
          }),
        }),
      }),
    ),
  )
  assert_eq(broker.session_count(), 0)
  assert_true(coordinator.has_pending())
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    let mut completed = false
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      if coordinator.committed_lsn() == 1L {
        completed = true
        break
      }
      @async.sleep(1)
    }
    assert_true(completed)
    assert_eq(broker.session_count(), 1)
    assert_eq(runtime.check_invariants(), Ok(()))
    driver.handle(
      Runtime(
        TransportClosed({ connection_id, reason: PeerEof, observed_at_ms: 2L }),
      ),
    )
    assert_eq(
      broker.session_attached(
        @session.ClientId::new("strict-driver-client").unwrap(),
      ),
      Some(true),
    )
    let mut will_committed = false
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      if coordinator.committed_lsn() == 3L {
        will_committed = true
        break
      }
      @async.sleep(1)
    }
    assert_true(will_committed)
    assert_eq(broker.retained_count(), 1)
    driver.strict_checkpoint_next_ms = @async.now() - 1L
    let mut checkpointed = false
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      if coordinator.checkpoint_lsn() == 3L &&
        !driver.strict_checkpoint_inflight {
        checkpointed = true
        break
      }
      @async.sleep(1)
    }
    assert_true(checkpointed)
    assert_false(driver.strict_checkpoint_degraded)
    assert_eq(
      broker.session_attached(
        @session.ClientId::new("strict-driver-client").unwrap(),
      ),
      Some(false),
    )
    assert_eq(runtime.check_invariants(), Ok(()))
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let limits = @persistence.SnapshotDecodeLimits::new(broker_config, 1024).unwrap()
  let (recovered_store, replay) = @persistence.WalStore::recover(lock, limits).unwrap()
  assert_eq(replay.checkpoint().lsn, 3L)
  let restored = replay.restore_state(broker_config, limits).unwrap()
  assert_eq(restored.state().retained_count(), 1)
  assert_eq(
    restored
    .state()
    .session_attached(@session.ClientId::new("strict-driver-client").unwrap()),
    Some(false),
  )
  recovered_store.close()
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}

///|
async test "checkpoint writer activity drains held control without requeue spin" {
  let path = "_build/server-strict-checkpoint-drain"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let broker = @router.BrokerState::new(broker_config)
  let runtime = BrokerRuntime::new(config, broker)
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let writer = @persistence.WalWriter::new(
    @persistence.WalStore::bootstrap(lock, {
      generation: 1L,
      lsn: 0L,
      identities: [],
      snapshot: { version: 3, sessions: [], retained: [] },
    }).unwrap(),
  )
  let coordinator = CommitCoordinator::new(
    writer,
    broker.resource_ledger(),
    33554432L,
    4194304,
    1L,
    0L,
  ).unwrap()
  let driver = RouterDriver::new(runtime, strict=coordinator)
  let checkpoint : @persistence.WalCheckpoint = {
    generation: 2L,
    lsn: 0L,
    identities: [],
    snapshot: {
      version: 3,
      sessions: [],
      retained: [
        {
          topic: "checkpoint/large",
          payload: Bytes::makei(8388608, index => (index % 251).to_byte()),
          qos: 0,
        },
      ],
    },
  }
  assert_true(writer.submit_checkpoint(checkpoint))
  driver.strict_checkpoint_inflight = true
  driver.strict_checkpoint_lsn = 0L
  let connection_id = ConnectionId::new(19L)
  driver.strict_held.push_back(
    (
      TransportClosed({
        connection_id,
        reason: PeerEof,
        observed_at_ms: @async.now(),
      }),
      None,
    ),
  )
  driver.strict_held_connections.set(connection_id, 1)
  driver.strict_management_held.push_back(
    RunCommand("held-reload", {
      kind: @management.Reload,
      target: "",
      if_match: "",
      idempotency_key: "checkpoint-held-reload",
      actor_token_id: "test",
    }),
  )
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    for _ in 0..<1000 {
      if writer.checkpoint_active() {
        break
      }
      @async.sleep(1)
    }
    assert_true(writer.checkpoint_active())
    driver.handle(WalCompletionDue)
    assert_eq(driver.strict_held.length(), 0)
    assert_eq(driver.strict_held_connections.length(), 0)
    assert_eq(driver.strict_management_held.length(), 0)
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      if !driver.strict_checkpoint_inflight {
        break
      }
      @async.sleep(1)
    }
    assert_false(driver.strict_checkpoint_inflight)
    assert_false(driver.strict_checkpoint_degraded)
    assert_eq(coordinator.checkpoint_generation(), 2L)
    assert_eq(coordinator.checkpoint_lsn(), 0L)
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}
