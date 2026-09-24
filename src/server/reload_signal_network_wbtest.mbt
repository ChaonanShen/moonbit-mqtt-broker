///|
async fn signal_test_digest(path : String) -> String {
  let (status, output, _) = @process.collect_output("sha256sum", [path])
  assert_eq(status, 0)
  output.text().split(" ").to_array()[0].to_owned()
}

///|
async fn signal_test_manifest(
  config_path : String,
  manifest_path : String,
) -> Unit {
  let value = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"" +
    signal_test_digest(config_path) +
    "\"\n"
  if @fs.exists(manifest_path) {
    @fs.remove(manifest_path)
  }
  @fs.write_file(
    manifest_path,
    @utf8.encode(value),
    create_mode=CreateNew,
    permission=0o600,
  )
}

///|
async test "signal coordinator prepares and publishes log generation without management" {
  let root = @fs.tmpdir(prefix="mqtt-reload-signal-")
  let config_path = root + "/config.toml"
  let manifest_path = root + "/manifest.toml"
  @fs.write_file(
    config_path,
    b"[observability]\nlog_level = \"info\"\n",
    create_mode=CreateNew,
    permission=0o600,
  )
  signal_test_manifest(config_path, manifest_path)
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
  let state = @router.BrokerState::new(broker_config)
  state.enable_policy_index().unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 20, broker_config).unwrap()
  let logger = @observability.Logger::new()
  let socket = @socket.TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
    reuse_addr=true,
  )
  let listener = ListenerConfig::new("mqtt", socket.addr.to_string(), 4).unwrap()
  let mut stop = false
  let mut signal = false
  let startup : ReloadStartup = {
    config_path,
    manifest_path,
    cli_args: [],
    runtime_root: root,
    prepare_timeout_ms: 30000,
    max_source_bytes: 16777216,
    max_generation_bytes: 67108864L,
    signal_pending: () => {
      if signal {
        signal = false
        true
      } else {
        false
      }
    },
  }
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      serve_listeners(
        [{ config: listener, socket }],
        config,
        state,
        shutdown_requested=() => stop,
        security=policy,
        logger~,
        generation=handle,
        reload_enabled=true,
        reload=startup,
      )
    })
    @fs.remove(config_path)
    @fs.write_file(
      config_path,
      b"[observability]\nlog_level = \"debug\"\n",
      create_mode=CreateNew,
      permission=0o600,
    )
    signal_test_manifest(config_path, manifest_path)
    signal = true
    let mut published = false
    for _ in 0..<500 {
      if handle.active().config_epoch() == 1L &&
        logger.render(
          @observability.LogRecord::new(
            1L,
            @observability.Debug,
            "after_reload",
          ),
        )
        is Some(_) {
        published = true
        break
      }
      @async.sleep(10)
    }
    stop = true
    assert_true(published)
    @async.with_timeout(3000, () => task.wait())
  }
  handle.close()
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.rmdir(root)
}
