///|
async test "kick stays running until exact transport unregister and leaves takeover alive" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let config_b = @management.ManagementConfig::new(
    enabled=true,
    token_file="/fixture/tokens",
    details_enabled=true,
    operations_enabled=true,
    max_bytes_total=33554432L,
  ).unwrap()
  let tokens = command_tokens()
  let management = ManagementRuntime::new(
    listener,
    { config: config_b, tokens },
    state.resource_ledger(),
  ).unwrap()
  let driver = RouterDriver::new(BrokerRuntime::new(config, state), management~)
  assert_true(
    driver.enable_management_connection_index(config.max_connections()),
  )
  let old = ConnectionId::new(21L)
  let old_sink = TransportSink::new(4)
  driver.handle(
    RegisterTransport({ connection_id: old, sink: old_sink, accepted_at_ms: 0L }),
  )
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id: old,
        packet: Connect({
          client_id: "same-client",
          username: None,
          password: None,
          keep_alive: 10,
          clean_session: false,
          will: None,
        }),
        received_at_ms: 1L,
      }),
    ),
  )
  ignore(old_sink.outbound().try_get())
  let actor = command_actor(tokens)
  let spec = @management.parse_command(
    "POST",
    "/v1/connections/21/disconnect",
    @management.connection_etag(management.context.boot_id, 21L),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let accepted = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(mailbox.wait(accepted).unwrap().status, @http_transport.Accepted)
  mailbox.release(accepted)
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  let operation_id = match
    management.operations
    .unwrap()
    .lookup_key(actor.token_id(), spec.idempotency_key, spec.normalized()) {
    @management.KeyMatch(record) => record.id
    _ => fail("missing kick operation")
  }
  assert_eq(
    management.operations.unwrap().get_internal(operation_id).unwrap().state,
    @management.Running,
  )
  assert_eq(old_sink.close_signal().try_get(), Some(AdminKick))
  assert_true(driver.runtime().has_connection(old))
  let newer = ConnectionId::new(22L)
  let new_sink = TransportSink::new(4)
  driver.handle(
    RegisterTransport({
      connection_id: newer,
      sink: new_sink,
      accepted_at_ms: 2L,
    }),
  )
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id: newer,
        packet: Connect({
          client_id: "same-client",
          username: None,
          password: None,
          keep_alive: 10,
          clean_session: false,
          will: None,
        }),
        received_at_ms: 3L,
      }),
    ),
  )
  assert_true(driver.runtime().has_connection(newer))
  driver.handle(
    Runtime(
      TransportClosed({
        connection_id: old,
        reason: AdminKick,
        observed_at_ms: 4L,
      }),
    ),
  )
  assert_eq(
    management.operations.unwrap().get_internal(operation_id).unwrap().state,
    @management.Running,
  )
  driver.handle(UnregisterTransport(old))
  let completed = management.operations
    .unwrap()
    .get_internal(operation_id)
    .unwrap()
  assert_eq(completed.state, @management.Succeeded)
  assert_true(completed.effect_applied)
  assert_true(completed.transport_closed)
  assert_true(driver.runtime().has_connection(newer))
  old_sink.close()
  new_sink.close()
  management.close()
}

///|
async test "kick closing intent prevents dispatch failure from overtaking terminal" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let config_b = @management.ManagementConfig::new(
    enabled=true,
    token_file="/fixture/tokens",
    details_enabled=true,
    operations_enabled=true,
    max_bytes_total=33554432L,
  ).unwrap()
  let tokens = command_tokens()
  let management = ManagementRuntime::new(
    listener,
    { config: config_b, tokens },
    state.resource_ledger(),
  ).unwrap()
  let driver = RouterDriver::new(BrokerRuntime::new(config, state), management~)
  assert_true(
    driver.enable_management_connection_index(config.max_connections()),
  )
  let id = ConnectionId::new(30L)
  let sink = TransportSink::new(1)
  driver.handle(
    RegisterTransport({ connection_id: id, sink, accepted_at_ms: 0L }),
  )
  let actor = command_actor(tokens)
  let spec = @management.parse_command(
    "POST",
    "/v1/connections/30/disconnect",
    @management.connection_etag(management.context.boot_id, 30L),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(mailbox.wait(ticket).unwrap().status, @http_transport.Accepted)
  mailbox.release(ticket)
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(sink.close_signal().try_get(), Some(AdminKick))
  assert_true(sink.outbound().try_put(WriteFrame(b"occupied")))
  driver.dispatch([SendPacket({ connection_id: id, packet: Pingresp })])
  assert_true(driver.runtime().has_connection(id))
  driver.handle(
    Runtime(
      TransportClosed({
        connection_id: id,
        reason: AdminKick,
        observed_at_ms: 1L,
      }),
    ),
  )
  driver.handle(UnregisterTransport(id))
  assert_false(driver.runtime().has_connection(id))
  sink.close()
  management.close()
}

///|
async test "kick waits for associated auth reap after terminal and unregister" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let config_b = @management.ManagementConfig::new(
    enabled=true,
    token_file="/fixture/tokens",
    details_enabled=true,
    operations_enabled=true,
    max_bytes_total=33554432L,
  ).unwrap()
  let tokens = command_tokens()
  let management = ManagementRuntime::new(
    listener,
    { config: config_b, tokens },
    state.resource_ledger(),
  ).unwrap()
  let driver = RouterDriver::new(BrokerRuntime::new(config, state), management~)
  assert_true(
    driver.enable_management_connection_index(config.max_connections()),
  )
  let id = ConnectionId::new(41L)
  let sink = TransportSink::new(2)
  driver.handle(
    RegisterTransport({ connection_id: id, sink, accepted_at_ms: 0L }),
  )
  driver.track_auth_association(999L, id)
  let actor = command_actor(tokens)
  let spec = @management.parse_command(
    "POST",
    "/v1/connections/41/disconnect",
    @management.connection_etag(management.context.boot_id, 41L),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(mailbox.wait(ticket).unwrap().status, @http_transport.Accepted)
  mailbox.release(ticket)
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  let op_id = match
    management.operations
    .unwrap()
    .lookup_key(actor.token_id(), spec.idempotency_key, spec.normalized()) {
    @management.KeyMatch(record) => record.id
    _ => fail("operation missing")
  }
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id: id,
        packet: Connect({
          client_id: "too-late",
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
  assert_eq(driver.runtime().connections.get(id).unwrap().phase, AwaitConnect)
  driver.handle(
    Runtime(
      TransportClosed({
        connection_id: id,
        reason: AdminKick,
        observed_at_ms: 2L,
      }),
    ),
  )
  driver.handle(UnregisterTransport(id))
  assert_eq(
    management.operations.unwrap().get_internal(op_id).unwrap().state,
    @management.Running,
  )
  assert_eq(
    management.operations.unwrap().get_internal(op_id).unwrap().stage,
    @management.WaitingAuthReap,
  )
  driver.clear_auth_association(999L)
  driver.poll_management_kicks()
  assert_eq(
    management.operations.unwrap().get_internal(op_id).unwrap().state,
    @management.Succeeded,
  )
  sink.close()
  management.close()
}

///|
async test "DISCONNECT before kick terminal suppresses historical Will" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let config_b = @management.ManagementConfig::new(
    enabled=true,
    token_file="/fixture/tokens",
    details_enabled=true,
    operations_enabled=true,
    max_bytes_total=33554432L,
  ).unwrap()
  let tokens = command_tokens()
  let management = ManagementRuntime::new(
    listener,
    { config: config_b, tokens },
    state.resource_ledger(),
  ).unwrap()
  let driver = RouterDriver::new(BrokerRuntime::new(config, state), management~)
  assert_true(
    driver.enable_management_connection_index(config.max_connections()),
  )
  let id = ConnectionId::new(51L)
  let sink = TransportSink::new(4)
  driver.handle(
    RegisterTransport({ connection_id: id, sink, accepted_at_ms: 0L }),
  )
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id: id,
        packet: Connect({
          client_id: "will-client",
          username: None,
          password: None,
          keep_alive: 10,
          clean_session: false,
          will: Some({
            topic: "will/topic",
            payload: b"would-fire",
            qos: @protocol.QoS0,
            retain: true,
          }),
        }),
        received_at_ms: 1L,
      }),
    ),
  )
  ignore(sink.outbound().try_get())
  let actor = command_actor(tokens)
  let spec = @management.parse_command(
    "POST",
    "/v1/connections/51/disconnect",
    @management.connection_etag(management.context.boot_id, 51L),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(mailbox.wait(ticket).unwrap().status, @http_transport.Accepted)
  mailbox.release(ticket)
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id: id,
        packet: Disconnect,
        received_at_ms: 2L,
      }),
    ),
  )
  assert_eq(state.retained_count(), 0)
  driver.handle(
    Runtime(
      TransportClosed({
        connection_id: id,
        reason: AdminKick,
        observed_at_ms: 3L,
      }),
    ),
  )
  driver.handle(UnregisterTransport(id))
  assert_eq(state.retained_count(), 0)
  sink.close()
  management.close()
}
