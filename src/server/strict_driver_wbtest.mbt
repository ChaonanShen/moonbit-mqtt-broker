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
      policy: None,
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
