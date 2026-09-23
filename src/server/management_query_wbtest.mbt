///|
fn management_query_driver() -> RouterDriver {
  let config = ServerConfig::default()
  RouterDriver::new(
    BrokerRuntime::new(config, @router.BrokerState::new(config.broker_config())),
  )
}

///|
fn management_query_register(
  driver : RouterDriver,
  id : ConnectionId,
  sink : TransportSink,
) -> Unit {
  driver.handle(
    RegisterTransport({ connection_id: id, sink, accepted_at_ms: 0L }),
  )
}

///|
fn management_query_connect(driver : RouterDriver, id : ConnectionId) -> Unit {
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id: id,
        packet: Connect({
          client_id: "managed",
          username: None,
          password: None,
          keep_alive: 10,
          clean_session: true,
          will: None,
        }),
        received_at_ms: 1L,
      }),
    ),
  )
}

///|
test "connection slot index reads current runtime phase and releases on unregister" {
  let driver = management_query_driver()
  assert_true(driver.enable_management_connection_index(2))
  let id = ConnectionId::new(44L)
  let sink = TransportSink::new(2)
  management_query_register(driver, id, sink)
  let page = driver
    .management_connection_page(0, 256, 50, fn(_) { true })
    .unwrap()
  assert_eq(page.keys, ["44"])
  assert_eq(
    driver.management_connection_view(44L).unwrap().phase,
    "await_connect",
  )
  management_query_connect(driver, id)
  assert_eq(
    driver.management_connection_view(44L).unwrap().client_id,
    Some("managed"),
  )
  driver.handle(
    Runtime(
      TransportClosed({ connection_id: id, reason: PeerEof, observed_at_ms: 2L }),
    ),
  )
  driver.handle(UnregisterTransport(id))
  assert_true(driver.management_connection_view(44L) is None)
  assert_eq(
    driver.management_connection_page(0, 256, 50, fn(_) { true }).unwrap().keys,
    [],
  )
  assert_true(driver.management_connections.unwrap().check_invariants())
  sink.close()
}

///|
test "connection index capacity failure disables details but not MQTT registration" {
  let driver = management_query_driver()
  assert_true(driver.enable_management_connection_index(1))
  let first = ConnectionId::new(1L)
  let second = ConnectionId::new(2L)
  let sink1 = TransportSink::new(2)
  let sink2 = TransportSink::new(2)
  management_query_register(driver, first, sink1)
  management_query_register(driver, second, sink2)
  assert_false(driver.management_connection_index_available())
  assert_true(driver.runtime().has_connection(first))
  assert_true(driver.runtime().has_connection(second))
  sink1.close()
  sink2.close()
}
