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
