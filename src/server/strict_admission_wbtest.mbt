///|
async test "oversized strict transaction closes only its connection before WAL write" {
  let path = "_build/server-strict-admission"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let config = ServerConfig::default()
  let broker = @router.BrokerState::new(config.broker_config())
  let runtime = BrokerRuntime::new(config, broker)
  let connection_id = ConnectionId::new(41L)
  ignore(runtime.apply(TransportOpened({ connection_id, accepted_at_ms: 0L })))
  ignore(
    runtime.apply(
      PacketReceived({
        connection_id,
        received_at_ms: 1L,
        packet: Connect({
          client_id: "oversized",
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
    64,
    1L,
    0L,
    broker~,
  ).unwrap()
  let driver = RouterDriver::new(runtime, strict=coordinator)
  let sink = TransportSink::new(4)
  driver.sinks.set(connection_id, sink)
  let before = broker.resource_ledger().reserved()
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id,
        received_at_ms: 2L,
        packet: Publish({
          topic: "large/delta",
          payload: b"payload",
          qos: QoS1,
          packet_id: Some(@protocol.PacketId::new(1).unwrap()),
          dup: false,
          retain: true,
        }),
      }),
    ),
  )
  assert_eq(sink.close_signal().try_get(), Some(ResourceExhausted))
  assert_false(coordinator.is_fenced())
  assert_false(coordinator.has_pending())
  assert_eq(broker.retained_count(), 0)
  assert_eq(broker.resource_ledger().reserved(), before)
  sink.close()
  writer.close_store()
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}
