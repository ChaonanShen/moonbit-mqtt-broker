///|
async fn ticker_test_manifest(
  config_path : String,
  manifest_path : String,
) -> Unit {
  let (status, output, _) = @process.collect_output("sha256sum", [config_path])
  assert_eq(status, 0)
  let value = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"" +
    output.text().split(" ").to_array()[0].to_owned() +
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
async test "ticker uses activated metrics interval without replaying old deadline" {
  let root = @fs.tmpdir(prefix="mqtt-reload-ticker-")
  let config_path = root + "/config.toml"
  let manifest_path = root + "/manifest.toml"
  @fs.write_file(
    config_path,
    b"[observability]\nsystem_metrics_interval_ms = 1000\n",
    create_mode=CreateNew,
    permission=0o600,
  )
  ticker_test_manifest(config_path, manifest_path)
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
  let broker = @router.BrokerState::new(broker_config)
  let config = ServerConfig::new(
    4,
    1024,
    2048,
    8,
    64,
    1000,
    100,
    broker_config,
    system_metrics_interval_ms=1000,
    auth_poll_interval_ms=20,
  ).unwrap()
  let events : @async.Queue[DriverEvent] = @async.Queue(kind=Blocking(64))
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      run_ticker(config, events, None, None, generation=handle)
    })
    @fs.remove(config_path)
    @fs.write_file(
      config_path,
      b"[observability]\nsystem_metrics_interval_ms = 1\n",
      create_mode=CreateNew,
      permission=0o600,
    )
    ticker_test_manifest(config_path, manifest_path)
    let pool = broker
      .resource_ledger()
      .pool(
        Infrastructure,
        broker_config.resources().get("max_managed_bytes_total"),
      )
      .unwrap()
    let prepared = match
      prepare_reload_candidate(
        manifest_path,
        config_path,
        [],
        bundle,
        effective,
        policy,
        pool,
        root,
        30000,
        16777216,
        67108864L,
      ) {
      ReloadPrepared(value) => value
      ReloadNoChange => fail("metrics period change was missed")
    }
    let old = handle.publish(prepared, 0L).unwrap()
    old.release()
    let mut emitted = false
    for _ in 0..<100 {
      let next = @async.with_timeout_opt(100, () => events.get())
      match next {
        Some(Runtime(EmitSystemMetrics(_))) => {
          emitted = true
          break
        }
        _ => ()
      }
    }
    task.cancel()
    task.wait() catch {
      _ => ()
    }
    assert_true(emitted)
  }
  events.close(clear=true)
  handle.close()
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.rmdir(root)
}
