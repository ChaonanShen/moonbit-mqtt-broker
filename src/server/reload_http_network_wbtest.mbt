///|
async test "reload-only management accepts JSON precondition and exposes operation" {
  let root = @fs.tmpdir(prefix="mqtt-reload-http-")
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
  let manifest_text = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"" +
    hash_output.text().split(" ").to_array()[0].to_owned() +
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
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 20, broker_config).unwrap()
  let state = @router.BrokerState::new(broker_config)
  state.enable_policy_index().unwrap()
  let mqtt_socket = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let admin_socket = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let admin_config = @management.ManagementConfig::new(
    enabled=true,
    token_file="/fixture/tokens",
    details_enabled=false,
    operations_enabled=false,
    request_timeout_ms=3000,
  ).unwrap()
  let tokens = @management.TokenDatabase::parse(
    @utf8.encode(
      "spike-token:dc211f3214c8dc9ccfdf0c2f2835ed515fc2e032d912934e1d700f8374747236:config_admin\n",
    ),
  ).unwrap()
  let management = ManagementRuntime::new(
    admin_socket,
    { config: admin_config, tokens },
    state.resource_ledger(),
  ).unwrap()
  management.enable_reload(handle, state.resource_ledger())
  let listener = ListenerConfig::new("mqtt", mqtt_socket.addr.to_string(), 4).unwrap()
  let startup : ReloadStartup = {
    config_path,
    manifest_path,
    cli_args: [],
    runtime_root: root,
    prepare_timeout_ms: 30000,
    max_source_bytes: 16777216,
    max_generation_bytes: 67108864L,
    signal_pending: () => false,
  }
  let mut stop = false
  let bearer = "Bearer spike-token." +
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      serve_listeners(
        [{ config: listener, socket: mqtt_socket }],
        config,
        state,
        shutdown_requested=() => stop,
        security=policy,
        management~,
        generation=handle,
        reload_enabled=true,
        reload=startup,
      )
    })
    let config_client = @socket.Tcp::connect(admin_socket.addr)
    config_client.write(
      @utf8.encode(
        "GET /v1/config HTTP/1.1\r\nHost: localhost\r\nAuthorization: " +
        bearer +
        "\r\n\r\n",
      ),
    )
    let config_response = @utf8.decode(config_client.read_all().binary())
    config_client.close()
    assert_true(config_response.has_prefix("HTTP/1.1 200 OK"))
    let etag = @management.config_etag(management.context.boot_id, 0L)
    assert_true(config_response.contains("ETag: " + etag + "\r\n"))
    let body = "{\"expected_generation\":0}"
    let post_client = @socket.Tcp::connect(admin_socket.addr)
    post_client.write(
      @utf8.encode(
        "POST /v1/config/reload HTTP/1.1\r\nHost: localhost\r\n" +
        "Authorization: " +
        bearer +
        "\r\n" +
        "If-Match: " +
        etag +
        "\r\n" +
        "Idempotency-Key: Key_0123456789abc\r\n" +
        "Content-Type: application/json\r\n" +
        "Content-Length: " +
        body.length().to_string() +
        "\r\n\r\n" +
        body,
      ),
    )
    let accepted = @utf8.decode(post_client.read_all().binary())
    post_client.close()
    assert_true(accepted.has_prefix("HTTP/1.1 202 Accepted"))
    assert_true(accepted.contains("\"kind\":\"reload\""))
    let mut succeeded = false
    for _ in 0..<300 {
      let table = management.operations.unwrap()
      if table.live_count() == 1 {
        let record = table.get(management.context.boot_id + ".1", "spike-token")
        if record is Some(value) && value.state == @management.Succeeded {
          succeeded = true
          break
        }
      }
      @async.sleep(10)
    }
    assert_true(succeeded)
    let operation_client = @socket.Tcp::connect(admin_socket.addr)
    operation_client.write(
      @utf8.encode(
        "GET /v1/operations/" +
        management.context.boot_id +
        ".1 HTTP/1.1\r\nHost: localhost\r\nAuthorization: " +
        bearer +
        "\r\n\r\n",
      ),
    )
    let operation_response = @utf8.decode(operation_client.read_all().binary())
    operation_client.close()
    assert_true(operation_response.has_prefix("HTTP/1.1 200 OK"))
    assert_true(operation_response.contains("\"state\":\"succeeded\""))
    stop = true
    @async.with_timeout(3000, () => task.wait())
  }
  management.close()
  handle.close()
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.rmdir(root)
}
