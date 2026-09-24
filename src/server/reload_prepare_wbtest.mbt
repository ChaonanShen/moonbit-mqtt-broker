///|
async fn reload_prepare_fixture_digest(path : String) -> String {
  let (status, output, _) = @process.collect_output("sha256sum", [path])
  assert_eq(status, 0)
  output.text().split(" ").to_array()[0].to_owned()
}

///|
async fn write_reload_prepare_fixture(
  config_path : String,
  manifest_path : String,
  contents : String,
) -> Unit {
  if @fs.exists(config_path) {
    @fs.remove(config_path)
  }
  if @fs.exists(manifest_path) {
    @fs.remove(manifest_path)
  }
  @fs.write_file(
    config_path,
    @utf8.encode(contents),
    create_mode=CreateNew,
    permission=0o600,
  )
  let manifest = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"" +
    reload_prepare_fixture_digest(config_path) +
    "\"\n"
  @fs.write_file(
    manifest_path,
    @utf8.encode(manifest),
    create_mode=CreateNew,
    permission=0o600,
  )
}

///|
async test "reload prepare distinguishes cosmetic change, hot change, and restart change" {
  let root = @fs.tmpdir(prefix="mqtt-reload-prepare-")
  let config_path = root + "/config.toml"
  let manifest_path = root + "/manifest.toml"
  let initial_text = "[observability]\nlog_level = \"info\"\n"
  write_reload_prepare_fixture(config_path, manifest_path, initial_text)
  let initial = @bundle.capture_bundle(manifest_path)
  let effective = initial.evaluate(config_path, [])
  let limits = @budget.Limits::default()
  let ledger = @budget.Ledger::new(
    limits.get("max_managed_bytes_total"),
    limits.get("control_reserve_bytes"),
  ).unwrap()
  let pool = ledger
    .pool(Infrastructure, limits.get("max_managed_bytes_total"))
    .unwrap()
  let baseline = ledger.occupied()
  write_reload_prepare_fixture(
    config_path,
    manifest_path,
    initial_text + "# harmless comment\n",
  )
  let no_change = prepare_reload_candidate(
    manifest_path,
    config_path,
    [],
    initial,
    effective,
    @security.SecurityPolicy::permissive(),
    pool,
    root,
    30000,
    16777216,
    67108864L,
  )
  assert_true(no_change is ReloadNoChange)
  assert_eq(ledger.occupied(), baseline)
  write_reload_prepare_fixture(
    config_path, manifest_path, "[observability]\nlog_level = \"debug\"\n",
  )
  let changed = prepare_reload_candidate(
    manifest_path,
    config_path,
    [],
    initial,
    effective,
    @security.SecurityPolicy::permissive(),
    pool,
    root,
    30000,
    16777216,
    67108864L,
  )
  let candidate = match changed {
    ReloadPrepared(value) => value
    ReloadNoChange => fail("hot log change was missed")
  }
  assert_false(candidate.security_changed())
  assert_true(ledger.occupied() > baseline)
  let handle = GenerationHandle::new(
    ConfigGeneration::initial(
      initial,
      effective,
      @security.SecurityPolicy::permissive(),
      initial.policy_fingerprint(effective),
    ),
  )
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let server_config = ServerConfig::new(
    4, 1024, 2048, 8, 32, 1000, 100, broker_config,
  ).unwrap()
  let logger = @observability.Logger::new()
  let runtime = BrokerRuntime::new(
    server_config,
    @router.BrokerState::new(broker_config),
    logger~,
  )
  let driver = RouterDriver::new(runtime, generation=handle)
  assert_eq(
    driver.activate_prepared_reload(candidate, 0L),
    ReloadActivated(1L, 0L),
  )
  assert_eq(handle.active().config_epoch(), 1L)
  assert_eq(handle.active().policy_epoch(), 0L)
  assert_true(
    logger.render(
      @observability.LogRecord::new(1L, @observability.Debug, "hot_log"),
    )
    is Some(_),
  )
  candidate.release()
  assert_true(ledger.occupied() > baseline)
  handle.close()
  assert_eq(ledger.occupied(), baseline)
  write_reload_prepare_fixture(
    config_path, manifest_path, "[server]\nmax_packet_size = 2048\n",
  )
  let rejected = try {
    ignore(
      prepare_reload_candidate(
        manifest_path,
        config_path,
        [],
        initial,
        effective,
        @security.SecurityPolicy::permissive(),
        pool,
        root,
        30000,
        16777216,
        67108864L,
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(ledger.occupied(), baseline)
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.rmdir(root)
}
