///|
fn strict_command_tokens() -> @management.TokenDatabase {
  @management.TokenDatabase::parse(
    @utf8.encode(
      "spike-token:dc211f3214c8dc9ccfdf0c2f2835ed515fc2e032d912934e1d700f8374747236:read,operator\n",
    ),
  ).unwrap()
}

///|
async test "strict offline delete succeeds only with committed LSN" {
  let path = "_build/server-strict-admin-delete"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
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
  let checkpoint : @persistence.WalCheckpoint = {
    generation: 1L,
    lsn: 0L,
    identities: [{ client_id: "delete-me", generation: 1L }],
    policy: None,
    snapshot: state.export_snapshot(),
  }
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let writer = @persistence.WalWriter::new(
    @persistence.WalStore::bootstrap(lock, checkpoint).unwrap(),
  )
  let coordinator = CommitCoordinator::new(
    writer,
    state.resource_ledger(),
    33554432L,
    1048576,
    1L,
    0L,
  ).unwrap()
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let tokens = strict_command_tokens()
  let management = ManagementRuntime::new(
    listener,
    {
      config: @management.ManagementConfig::new(
        enabled=true,
        token_file="/fixture/tokens",
        details_enabled=true,
        operations_enabled=true,
        max_bytes_total=33554432L,
      ).unwrap(),
      tokens,
    },
    state.resource_ledger(),
  ).unwrap()
  let driver = RouterDriver::new(
    BrokerRuntime::new(config, state),
    strict=coordinator,
    strict_generations=Map([(client_id, 1L)]),
    management~,
  )
  assert_true(
    driver.enable_management_connection_index(config.max_connections()),
  )
  let actor = tokens
    .authenticate(
      "spike-token.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    )
    .unwrap()
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
  let operation_id = match
    management.operations
    .unwrap()
    .lookup_key(actor.token_id(), spec.idempotency_key, spec.normalized()) {
    @management.KeyMatch(record) => record.id
    _ => fail("strict operation missing")
  }
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_true(state.has_session(client_id))
  assert_eq(
    management.operations.unwrap().get_internal(operation_id).unwrap().state,
    @management.Running,
  )
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
    assert_false(state.has_session(client_id))
    let operation = management.operations
      .unwrap()
      .get_internal(operation_id)
      .unwrap()
    assert_eq(operation.state, @management.Succeeded)
    assert_eq(operation.committed_lsn_at_finish, Some(1L))
    assert_eq(operation.completion_scope, "durable")
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  management.close()
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}

///|
async test "strict kick waits for socket close auth reap and durable detach" {
  let path = "_build/server-strict-admin-kick"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  assert_true(state.enable_management_index())
  let runtime = BrokerRuntime::new(config, state)
  let connection_id = ConnectionId::new(31L)
  ignore(runtime.apply(TransportOpened({ connection_id, accepted_at_ms: 0L })))
  ignore(
    runtime.apply(
      PacketReceived({
        connection_id,
        received_at_ms: 1L,
        packet: Connect({
          client_id: "kick-me",
          username: None,
          password: None,
          keep_alive: 10,
          clean_session: false,
          will: None,
        }),
      }),
    ),
  )
  let client_id = @session.ClientId::new("kick-me").unwrap()
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let writer = @persistence.WalWriter::new(
    @persistence.WalStore::bootstrap(lock, {
      generation: 1L,
      lsn: 0L,
      identities: [{ client_id: "kick-me", generation: 1L }],
      policy: None,
      snapshot: state.export_snapshot(),
    }).unwrap(),
  )
  let coordinator = CommitCoordinator::new(
    writer,
    state.resource_ledger(),
    33554432L,
    1048576,
    1L,
    0L,
  ).unwrap()
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let tokens = strict_command_tokens()
  let management = ManagementRuntime::new(
    listener,
    {
      config: @management.ManagementConfig::new(
        enabled=true,
        token_file="/fixture/tokens",
        details_enabled=true,
        operations_enabled=true,
        max_bytes_total=33554432L,
      ).unwrap(),
      tokens,
    },
    state.resource_ledger(),
  ).unwrap()
  let driver = RouterDriver::new(
    runtime,
    strict=coordinator,
    strict_generations=Map([(client_id, 1L)]),
    management~,
  )
  let sink = TransportSink::new(4)
  driver.sinks.set(connection_id, sink)
  assert_true(
    driver.enable_management_connection_index(config.max_connections()),
  )
  let actor = tokens
    .authenticate(
      "spike-token.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    )
    .unwrap()
  let spec = @management.parse_command(
    "POST",
    "/v1/connections/31/disconnect",
    @management.connection_etag(management.context.boot_id, 31L),
    "Key_0123456789abd",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(mailbox.wait(ticket).unwrap().status, @http_transport.Accepted)
  mailbox.release(ticket)
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  let operation_id = match
    management.operations
    .unwrap()
    .lookup_key(actor.token_id(), spec.idempotency_key, spec.normalized()) {
    @management.KeyMatch(record) => record.id
    _ => fail("strict kick missing")
  }
  assert_eq(sink.close_signal().try_get(), Some(AdminKick))
  driver.handle(
    Runtime(
      TransportClosed({ connection_id, reason: AdminKick, observed_at_ms: 2L }),
    ),
  )
  driver.handle(UnregisterTransport(connection_id))
  assert_eq(
    management.operations.unwrap().get_internal(operation_id).unwrap().state,
    @management.Running,
  )
  assert_eq(state.session_attached(client_id), Some(true))
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
    assert_eq(state.session_attached(client_id), Some(false))
    let operation = management.operations
      .unwrap()
      .get_internal(operation_id)
      .unwrap()
    assert_eq(operation.state, @management.Succeeded)
    assert_eq(operation.committed_lsn_at_finish, Some(1L))
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  sink.close()
  management.close()
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}
