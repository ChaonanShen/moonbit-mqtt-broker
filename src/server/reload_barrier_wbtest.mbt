///|
async test "strict reload barrier drains older WAL and holds later business" {
  let path = "_build/server-reload-barrier"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let broker = @router.BrokerState::new(broker_config)
  let runtime = BrokerRuntime::new(config, broker)
  let connection_id = ConnectionId::new(41L)
  ignore(runtime.apply(TransportOpened({ connection_id, accepted_at_ms: 0L })))
  ignore(
    runtime.apply(
      PacketReceived({
        connection_id,
        received_at_ms: 1L,
        packet: Connect({
          client_id: "reload-barrier",
          username: None,
          password: None,
          keep_alive: 10,
          clean_session: true,
          will: None,
        }),
      }),
    ),
  )
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
  driver.strict_checkpoint_cursor = Some(broker.start_snapshot_export(Map([])))
  assert_false(driver.begin_reload_barrier())
  driver.strict_checkpoint_cursor = None
  driver.strict_checkpoint_inflight = true
  assert_false(driver.begin_reload_barrier())
  driver.strict_checkpoint_inflight = false
  let publish = fn(topic : String, packet_id : Int) {
    driver.handle(
      Runtime(
        PacketReceived({
          connection_id,
          received_at_ms: packet_id.to_int64(),
          packet: Publish({
            topic,
            payload: b"value",
            qos: QoS1,
            packet_id: Some(@protocol.PacketId::new(packet_id).unwrap()),
            dup: false,
            retain: true,
          }),
        }),
      ),
    )
  }
  publish("barrier/one", 1)
  assert_true(coordinator.has_pending())
  assert_true(driver.begin_reload_barrier())
  assert_false(driver.begin_reload_barrier())
  publish("barrier/two", 2)
  assert_eq(driver.strict_held.length(), 1)
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    let mut ready = false
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      if driver.reload_barrier_ready() {
        ready = true
        break
      }
      @async.sleep(1)
    }
    assert_true(ready)
    assert_eq(broker.retained_count(), 1)
    assert_eq(driver.strict_held.length(), 1)
    driver.end_reload_barrier()
    assert_eq(driver.strict_held.length(), 0)
    let mut committed = false
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      if coordinator.committed_lsn() == 2L {
        committed = true
        break
      }
      @async.sleep(1)
    }
    assert_true(committed)
    assert_eq(broker.retained_count(), 2)
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}
