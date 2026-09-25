///|
async test "strict pending WAL lets another MQTT PING progress without overtaking same connection" {
  let path = "_build/server-strict-ping-barrier"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let broker = @router.BrokerState::new(broker_config)
  let runtime = BrokerRuntime::new(config, broker)
  let first = ConnectionId::new(21L)
  let other = ConnectionId::new(22L)
  for pair in [(first, "first"), (other, "other")] {
    let (connection_id, client_id) = pair
    ignore(
      runtime.apply(TransportOpened({ connection_id, accepted_at_ms: 0L })),
    )
    ignore(
      runtime.apply(
        PacketReceived({
          connection_id,
          received_at_ms: 1L,
          packet: Connect({
            client_id,
            username: None,
            password: None,
            keep_alive: 10,
            clean_session: true,
            will: None,
          }),
        }),
      ),
    )
  }
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
  let first_sink = TransportSink::new(4)
  let other_sink = TransportSink::new(4)
  driver.sinks.set(first, first_sink)
  driver.sinks.set(other, other_sink)
  let packet_id = @protocol.PacketId::new(7).unwrap()
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id: first,
        received_at_ms: 2L,
        packet: Publish({
          topic: "data",
          payload: b"value",
          qos: QoS1,
          packet_id: Some(packet_id),
          dup: false,
          retain: true,
        }),
      }),
    ),
  )
  assert_true(coordinator.has_pending())
  assert_eq(broker.retained_count(), 0)
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id: other,
        packet: Pingreq,
        received_at_ms: 3L,
      }),
    ),
  )
  assert_eq(other_sink.outbound().try_get(), Some(WriteFrame(b"\xd0\x00")))
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id: first,
        packet: Pingreq,
        received_at_ms: 3L,
      }),
    ),
  )
  assert_true(first_sink.outbound().try_get() is None)
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id: other,
        packet: Pingreq,
        received_at_ms: 4L,
      }),
    ),
  )
  assert_eq(other_sink.outbound().try_get(), Some(WriteFrame(b"\xd0\x00")))
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
    assert_true(first_sink.outbound().try_get() is Some(WriteFrame(_)))
    assert_eq(first_sink.outbound().try_get(), Some(WriteFrame(b"\xd0\x00")))
    assert_eq(broker.retained_count(), 1)
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  first_sink.close()
  other_sink.close()
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}
