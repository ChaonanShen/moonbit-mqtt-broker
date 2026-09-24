///|
async test "config admin accepts reload with B features disabled and reads own operation" {
  let root = @fs.tmpdir(prefix="mqtt-reload-admin-")
  let config_path = root + "/config.toml"
  let manifest_path = root + "/manifest.toml"
  @fs.write_file(
    config_path,
    b"[observability]\nlog_level = \"info\"\n",
    create_mode=CreateNew,
    permission=0o600,
  )
  let (hash_status, hash_output, _) = @process.collect_output("sha256sum", [
    config_path,
  ])
  assert_eq(hash_status, 0)
  let digest = hash_output.text().split(" ").to_array()[0].to_owned()
  let manifest_text = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"" +
    digest +
    "\"\n"
  @fs.write_file(
    manifest_path,
    @utf8.encode(manifest_text),
    create_mode=CreateNew,
    permission=0o600,
  )
  let bundle = @bundle.capture_bundle(manifest_path)
  let effective = bundle.evaluate(config_path, [])
  let policy = @security.SecurityPolicy::permissive()
  let handle = GenerationHandle::new(
    ConfigGeneration::initial(
      bundle,
      effective,
      policy,
      bundle.policy_fingerprint(effective),
    ),
  )
  let config = ServerConfig::default()
  let broker = @router.BrokerState::new(config.broker_config())
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let admin_config = @management.ManagementConfig::new(
    enabled=true,
    token_file="/fixture/tokens",
    details_enabled=false,
    operations_enabled=false,
  ).unwrap()
  let tokens = @management.TokenDatabase::parse(
    @utf8.encode(
      "spike-token:dc211f3214c8dc9ccfdf0c2f2835ed515fc2e032d912934e1d700f8374747236:config_admin\n",
    ),
  ).unwrap()
  let management = ManagementRuntime::new(
    listener,
    { config: admin_config, tokens },
    broker.resource_ledger(),
  ).unwrap()
  management.enable_reload(handle, broker.resource_ledger())
  let service = ReloadService::new(
    Some(management),
    broker.resource_ledger(),
    "off",
  )
  let runtime = BrokerRuntime::new(config, broker, security=policy)
  let driver = RouterDriver::new(
    runtime,
    management~,
    generation=handle,
    reload_service=service,
  )
  let actor = tokens
    .authenticate(
      "spike-token.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    )
    .unwrap()
  let spec = @management.parse_command(
    "POST",
    "/v1/config/reload",
    @management.config_etag(management.context.boot_id, 0L),
    "Key_0123456789abc",
    actor.token_id(),
  ).unwrap()
  let mailbox = management.command_mailbox.unwrap()
  let ticket = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  let response = mailbox.wait(ticket).unwrap()
  assert_eq(response.status, @http_transport.Accepted)
  let location = response.location.unwrap()
  mailbox.release(ticket)
  let again = mailbox.submit(spec, actor).unwrap()
  driver.handle(ManagementCommand(mailbox.take().unwrap()))
  assert_eq(mailbox.wait(again).unwrap().location, Some(location))
  mailbox.release(again)
  let query : @management.QuerySpec = {
    kind: @management.Operation,
    target: location["/v1/operations/".length():].to_owned(),
    actor_token_id: actor.token_id(),
    limit: 1,
    cursor: None,
    filters: "",
  }
  let queries = management.query_mailbox.unwrap()
  let qticket = queries.submit(query).unwrap()
  driver.handle(ManagementQuery(queries.take().unwrap()))
  let read = queries.wait(qticket).unwrap()
  assert_eq(read.status, @http_transport.Ok)
  assert_true(@utf8.decode(read.body).contains("\"kind\":\"reload\""))
  queries.release(qticket)
  service.close()
  management.close()
  handle.close()
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.rmdir(root)
}
