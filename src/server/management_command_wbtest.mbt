///|
fn command_tokens() -> @management.TokenDatabase {
  @management.TokenDatabase::parse(
    @utf8.encode(
      "spike-token:dc211f3214c8dc9ccfdf0c2f2835ed515fc2e032d912934e1d700f8374747236:read,operator\n",
    ),
  ).unwrap()
}

///|
fn command_actor(
  tokens : @management.TokenDatabase,
) -> @management.AdminPrincipal {
  tokens
  .authenticate(
    "spike-token.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  )
  .unwrap()
}

///|
async test "delete acceptance is idempotent and run releases offline state once" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let client_id = @session.ClientId::new("delete-me").unwrap()
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
  let identity = state
    .management_index()
    .unwrap()
    .identity_for_client(client_id)
    .unwrap()
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
  let actor = command_actor(tokens)
  let spec = @management.parse_command(
    "DELETE",
    "/v1/sessions/" + identity.handle.to_string(),
    @management.session_etag(
      management.context.boot_id,
      identity.handle,
      identity.lifecycle_version,
    ),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  let response = mailbox.wait(ticket).unwrap()
  assert_eq(response.status, @http_transport.Accepted)
  assert_true(response.location is Some(_))
  let table = management.operations.unwrap()
  assert_eq(table.live_count(), 1)
  let operation_id = table.lookup_key(
    actor.token_id(),
    spec.idempotency_key,
    spec.normalized(),
  )
  let id = match operation_id {
    @management.KeyMatch(record) => record.id
    _ => fail("accepted operation missing")
  }
  mailbox.release(ticket)
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_false(state.has_session(client_id))
  let completed = table.get_internal(id).unwrap()
  assert_eq(completed.state, @management.Succeeded)
  assert_true(completed.effect_applied)
  assert_eq(completed.completion_scope, "runtime")
  assert_eq(management.audit.unwrap().count(), 3)
  let retry = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(mailbox.wait(retry).unwrap().status, @http_transport.Ok)
  mailbox.release(retry)
  assert_eq(table.live_count(), 1)
  management.close()
}

///|
async test "stale offline etag returns precondition failure before 202" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let client_id = @session.ClientId::new("reconnected").unwrap()
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
  let identity = state
    .management_index()
    .unwrap()
    .identity_for_client(client_id)
    .unwrap()
  ignore(state.apply(@router.AttachSession(client_id)).unwrap())
  ignore(state.apply(@router.DetachSession(client_id)).unwrap())
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
  let actor = command_actor(tokens)
  let spec = @management.parse_command(
    "DELETE",
    "/v1/sessions/" + identity.handle.to_string(),
    @management.session_etag(management.context.boot_id, identity.handle, 1L),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(
    mailbox.wait(ticket).unwrap().status,
    @http_transport.PreconditionFailed,
  )
  assert_eq(management.operations.unwrap().live_count(), 0)
  assert_true(state.has_session(client_id))
  mailbox.release(ticket)
  management.close()
}

///|
async test "shutdown fails accepted queued command without applying delete" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let client_id = @session.ClientId::new("shutdown-queued").unwrap()
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
  let identity = state
    .management_index()
    .unwrap()
    .identity_for_client(client_id)
    .unwrap()
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
  let data : @async.Queue[DriverEvent] = @async.Queue(kind=Blocking(16))
  let bus = EventBus::new(config, state.resource_ledger(), data).unwrap()
  bus.attach_management_commands(management.command_mailbox.unwrap())
  let actor = command_actor(tokens)
  let spec = @management.parse_command(
    "DELETE",
    "/v1/sessions/" + identity.handle.to_string(),
    @management.session_etag(management.context.boot_id, identity.handle, 1L),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(mailbox.wait(ticket).unwrap().status, @http_transport.Accepted)
  mailbox.release(ticket)
  driver.shutdown_management(bus)
  let record = match
    management.operations
    .unwrap()
    .lookup_key(actor.token_id(), spec.idempotency_key, spec.normalized()) {
    @management.KeyMatch(value) => value
    _ => fail("missing accepted record")
  }
  assert_eq(record.state, @management.Failed)
  assert_false(record.effect_applied)
  assert_eq(record.error_code, Some("shutdown"))
  assert_true(state.has_session(client_id))
  bus.close()
  management.close()
}

///|
async test "queued delete rechecks offline ABA after reconnect before effect" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let client_id = @session.ClientId::new("queued-aba").unwrap()
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
  let identity = state
    .management_index()
    .unwrap()
    .identity_for_client(client_id)
    .unwrap()
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
  let actor = command_actor(tokens)
  let spec = @management.parse_command(
    "DELETE",
    "/v1/sessions/" + identity.handle.to_string(),
    @management.session_etag(management.context.boot_id, identity.handle, 1L),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(mailbox.wait(ticket).unwrap().status, @http_transport.Accepted)
  mailbox.release(ticket)
  ignore(state.apply(@router.AttachSession(client_id)).unwrap())
  ignore(state.apply(@router.DetachSession(client_id)).unwrap())
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  let record = match
    management.operations
    .unwrap()
    .lookup_key(actor.token_id(), spec.idempotency_key, spec.normalized()) {
    @management.KeyMatch(value) => value
    _ => fail("operation missing")
  }
  assert_eq(record.state, @management.Failed)
  assert_eq(record.error_code, Some("precondition_failed"))
  assert_false(record.effect_applied)
  assert_true(state.has_session(client_id))
  management.close()
}

///|
async test "offline delete dispatches promotion unlocked for another active session" {
  let broker = @router.BrokerConfig::new(
    4,
    16,
    4,
    max_sessions=4,
    max_inflight_per_session=1,
    max_inflight_total=1,
    max_pending_per_session=2,
    max_pending_total=4,
  ).unwrap()
  let config = ServerConfig::new(4, 4096, 4096, 8, 64, 10000, 100, broker).unwrap()
  let state = @router.BrokerState::new(broker)
  let old = @session.ClientId::new("old-inflight").unwrap()
  let other = @session.ClientId::new("other-pending").unwrap()
  ignore(
    state
    .apply(
      @router.CreateSessionWith({
        client_id: old,
        mode: @session.Persistent,
        attached: true,
      }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(
      @router.Subscribe({
        client_id: old,
        entries: [
          {
            filter: @topic.TopicFilter::new("old").unwrap(),
            qos: @session.QoS1,
          },
        ],
      }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(
      @router.Publish({
        origin: @router.PublishOrigin::Internal,
        topic: @topic.TopicName::new("old").unwrap(),
        payload: b"held",
        qos: @session.QoS1,
        retain: false,
      }),
    )
    .unwrap(),
  )
  ignore(state.apply(@router.DetachSession(old)).unwrap())
  ignore(
    state
    .apply(
      @router.CreateSessionWith({
        client_id: other,
        mode: @session.Persistent,
        attached: false,
      }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(
      @router.Subscribe({
        client_id: other,
        entries: [
          {
            filter: @topic.TopicFilter::new("other").unwrap(),
            qos: @session.QoS1,
          },
        ],
      }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(
      @router.Publish({
        origin: @router.PublishOrigin::Internal,
        topic: @topic.TopicName::new("other").unwrap(),
        payload: b"promoted",
        qos: @session.QoS1,
        retain: false,
      }),
    )
    .unwrap(),
  )
  assert_eq(state.inflight_count(), 1)
  assert_eq(state.pending_qos1_count(), 1)
  assert_true(state.enable_management_index())
  let identity = state
    .management_index()
    .unwrap()
    .identity_for_client(old)
    .unwrap()
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
  let other_connection = ConnectionId::new(72L)
  let sink = TransportSink::new(8)
  driver.handle(
    RegisterTransport({
      connection_id: other_connection,
      sink,
      accepted_at_ms: 0L,
    }),
  )
  driver.handle(
    Runtime(
      PacketReceived({
        connection_id: other_connection,
        packet: Connect({
          client_id: "other-pending",
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
  assert_true(sink.outbound().try_get() is Some(WriteFrame(_)))
  let actor = command_actor(tokens)
  let spec = @management.parse_command(
    "DELETE",
    "/v1/sessions/" + identity.handle.to_string(),
    @management.session_etag(
      management.context.boot_id,
      identity.handle,
      identity.lifecycle_version,
    ),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(mailbox.wait(ticket).unwrap().status, @http_transport.Accepted)
  mailbox.release(ticket)
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  match sink.outbound().try_get() {
    Some(WriteFrame(frame)) =>
      match @protocol.decode_packet(frame) {
        Ok(@protocol.Publish(publish)) =>
          assert_eq(publish.payload, b"promoted")
        _ => fail("expected promoted publish after admin delete")
      }
    _ => fail("promotion was not dispatched")
  }
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(state.inflight_count(), 1)
  sink.close()
  management.close()
}

///|
async test "failed snapshot submission does not upgrade runtime delete to durable" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let client_id = @session.ClientId::new("snapshot-failed-delete").unwrap()
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
  let identity = state
    .management_index()
    .unwrap()
    .identity_for_client(client_id)
    .unwrap()
  let path = "/tmp/b37-management-" + @management.new_boot_id().unwrap()
  let disk = @persistence.PersistenceConfig::new(
    path,
    debounce_ms=1L,
    max_delay_ms=1L,
    retry_ms=1L,
  ).unwrap()
  let store = @persistence.SnapshotStore::open(disk).unwrap()
  let persistence = PersistenceRuntime::new(store, disk).unwrap()
  persistence.sink.close()
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
    persistence~,
  ).unwrap()
  let driver = RouterDriver::new(
    BrokerRuntime::new(config, state),
    snapshot=persistence.driver_config(),
    management~,
  )
  assert_true(
    driver.enable_management_connection_index(config.max_connections()),
  )
  let actor = command_actor(tokens)
  let spec = @management.parse_command(
    "DELETE",
    "/v1/sessions/" + identity.handle.to_string(),
    @management.session_etag(management.context.boot_id, identity.handle, 1L),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(mailbox.wait(ticket).unwrap().status, @http_transport.Accepted)
  mailbox.release(ticket)
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  let record = match
    management.operations
    .unwrap()
    .lookup_key(actor.token_id(), spec.idempotency_key, spec.normalized()) {
    @management.KeyMatch(value) => value
    _ => fail("operation missing")
  }
  assert_eq(record.state, @management.Succeeded)
  assert_true(record.effect_applied)
  assert_eq(record.persistence_mode, "snapshot")
  assert_eq(record.completion_scope, "runtime")
  assert_eq(record.snapshot_committed_revision_at_finish, None)
  assert_eq(persistence.committed_revision(), -1L)
  assert_false(state.has_session(client_id))
  management.close()
  persistence.close()
}

///|
async test "command scheduling failure rolls back Operation before 202" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let client_id = @session.ClientId::new("reserve-rollback").unwrap()
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
  let identity = state
    .management_index()
    .unwrap()
    .identity_for_client(client_id)
    .unwrap()
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
  let actor = command_actor(tokens)
  let spec = @management.parse_command(
    "DELETE",
    "/v1/sessions/" + identity.handle.to_string(),
    @management.session_etag(management.context.boot_id, identity.handle, 1L),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  let event = mailbox.take().unwrap()
  ignore(mailbox.close())
  driver.handle(ManagementCommand(event))
  let reply = mailbox.wait(ticket).unwrap()
  assert_eq(reply.status, @http_transport.TooManyRequests)
  assert_eq(management.operations.unwrap().live_count(), 0)
  assert_eq(management.audit.unwrap().count(), 0)
  assert_true(state.has_session(client_id))
  mailbox.release(ticket)
  management.close()
}
