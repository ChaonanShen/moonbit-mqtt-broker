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

///|
async test "typed query reads session detail and bounded page from driver" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  let client_id = @session.ClientId::new("detail-client").unwrap()
  ignore(
    state
    .apply(
      @router.CreateSessionWith({
        client_id,
        mode: @session.Persistent,
        attached: false,
      }),
    )
    .unwrap(),
  )
  assert_true(state.enable_management_index())
  let id = state
    .management_index()
    .unwrap()
    .identity_for_client(client_id)
    .unwrap()
  let baseline = state.resource_ledger().occupied()
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let management_config = @management.ManagementConfig::new(
    enabled=true,
    token_file="/fixture/tokens",
    details_enabled=true,
    max_bytes_total=33554432L,
  ).unwrap()
  let management = ManagementRuntime::new(
    listener,
    { config: management_config, tokens: lifecycle_startup().tokens },
    state.resource_ledger(),
  ).unwrap()
  let driver = RouterDriver::new(BrokerRuntime::new(config, state), management~)
  assert_true(
    driver.enable_management_connection_index(config.max_connections()),
  )
  let mailbox = management.query_mailbox.unwrap()
  let detail : @management.QuerySpec = {
    kind: @management.Session,
    target: id.handle.to_string(),
    actor_token_id: "reader",
    limit: 50,
    cursor: None,
    filters: "",
  }
  let ticket = mailbox.submit(detail).unwrap()
  let event = mailbox.take().unwrap()
  driver.handle(ManagementQuery(event))
  let result = mailbox.wait(ticket).unwrap()
  let body = @utf8.decode(result.body)
  assert_eq(result.status, @http_transport.Ok)
  assert_true(body.contains("\"client_id\":\"detail-client\""))
  assert_true(body.contains("\"lifecycle_version\":\"1\""))
  assert_true(body.contains("\"last_protocol\":4"))
  assert_true(body.contains("\"retention\":\"legacy_broker_policy\""))
  assert_true(body.contains("\"will_count\":0"))
  mailbox.release(ticket)
  let list : @management.QuerySpec = {
    kind: @management.Sessions,
    target: "",
    actor_token_id: "reader",
    limit: 1,
    cursor: None,
    filters: "",
  }
  let ticket2 = mailbox.submit(list).unwrap()
  driver.handle(ManagementQuery(mailbox.take().unwrap()))
  let page = mailbox.wait(ticket2).unwrap()
  assert_eq(page.status, @http_transport.Ok)
  assert_true(@utf8.decode(page.body).contains("\"consistency\":\"per_page\""))
  mailbox.release(ticket2)
  management.close()
  assert_eq(state.resource_ledger().occupied(), baseline)
}

///|
test "retained metadata preflight rejects escape expansion before JSON copy" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let name = @utf8.decode(Bytes::make(33000, 34))
  let topic = @topic.TopicName::new(name).unwrap()
  ignore(
    state
    .apply(
      @router.Publish({
        origin: @router.PublishOrigin::Internal,
        topic,
        payload: b"x",
        qos: @session.QoS0,
        retain: true,
      }),
    )
    .unwrap(),
  )
  let driver = RouterDriver::new(BrokerRuntime::new(config, state))
  assert_true(
    management_row_key_too_large(
      @management.Retained,
      name,
      state,
      driver,
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      65536,
    ),
  )
  assert_eq(state.retained_count(), 1)
  assert_eq(state.admin_retained_view(name).unwrap().payload_bytes, 1L)
}

///|
async test "oversized escaped retained row returns finite 422 without cursor" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let name = @utf8.decode(Bytes::make(33000, 34))
  ignore(
    state
    .apply(
      @router.Publish({
        origin: @router.PublishOrigin::Internal,
        topic: @topic.TopicName::new(name).unwrap(),
        payload: b"x",
        qos: @session.QoS0,
        retain: true,
      }),
    )
    .unwrap(),
  )
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let config_b = @management.ManagementConfig::new(
    enabled=true,
    token_file="/fixture/tokens",
    details_enabled=true,
    max_bytes_total=33554432L,
  ).unwrap()
  let management = ManagementRuntime::new(
    listener,
    { config: config_b, tokens: lifecycle_startup().tokens },
    state.resource_ledger(),
  ).unwrap()
  let driver = RouterDriver::new(BrokerRuntime::new(config, state), management~)
  assert_true(
    driver.enable_management_connection_index(config.max_connections()),
  )
  let spec : @management.QuerySpec = {
    kind: @management.Retained,
    target: "",
    actor_token_id: "reader",
    limit: 50,
    cursor: None,
    filters: "",
  }
  let result = driver.management_query_result(spec, management)
  assert_eq(result.status, @http_transport.Unprocessable)
  assert_true(@utf8.decode(result.body).contains("result_too_large"))
  assert_eq(management.cursor_table.unwrap().live_count(), 0)
  management.close()
}

///|
test "C-T38 management connection view exposes bounded MQTT5 negotiation" {
  let base = ServerConfig::default()
  let config : ServerConfig = {
    ..base,
    protocol_config: @config.ProtocolConfig::new(mqtt5_enabled=true).unwrap(),
  }
  let state = @router.BrokerState::new(config.broker_config())
  let driver = RouterDriver::new(BrokerRuntime::new(config, state))
  assert_true(driver.enable_management_connection_index(4))
  let id = ConnectionId::new(55L)
  let sink = TransportSink::new(4)
  management_query_register(driver, id, sink)
  driver.handle(
    Runtime(
      Mqtt5PacketReceived({
        connection_id: id,
        packet: @protocol.Connect5({
          client_id: "managed-v5",
          username: None,
          password: None,
          keep_alive: 10,
          clean_start: true,
          properties: [{ id: 0x21, value: @protocol.TwoByteValue(3) }],
          will: None,
        }),
        received_at_ms: 1L,
        rx_permit: None,
        rx_error: None,
      }),
    ),
  )
  let view = driver.management_connection_view(55L).unwrap()
  assert_eq(view.protocol, "5")
  assert_eq(view.peer_receive_maximum, Some(3))
  assert_eq(view.tx_available, Some(3))
  assert_eq(view.rx_inflight, Some(0))
  let json = management_connection_json(
    view, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  ).stringify()
  assert_true(json.contains("\"protocol\":\"5\""))
  assert_true(json.contains("\"peer_receive_maximum\":3"))
  sink.close()
}
