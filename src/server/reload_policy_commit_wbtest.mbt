///|
async fn strict_reload_digest(path : String) -> String {
  let (status, output, _) = @process.collect_output("sha256sum", [path])
  assert_eq(status, 0)
  output.text().split(" ").to_array()[0].to_owned()
}

///|
async fn strict_reload_manifest(
  config_path : String,
  manifest_path : String,
  acl_path : String?,
) -> Unit {
  let mut text = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"" +
    strict_reload_digest(config_path) +
    "\"\n"
  if acl_path is Some(path) {
    text += "[[materials]]\nrole = \"acl\"\npath = \"" +
      path +
      "\"\nsha256 = \"" +
      strict_reload_digest(path) +
      "\"\n"
  }
  if @fs.exists(manifest_path) {
    @fs.remove(manifest_path)
  }
  @fs.write_file(
    manifest_path,
    @utf8.encode(text),
    create_mode=CreateNew,
    permission=0o600,
  )
}

///|
async test "strict reload commits policy before root swap and finishes cleanup" {
  let root = @fs.tmpdir(prefix="mqtt-reload-commit-")
  let data_dir = root + "/data"
  let config_path = root + "/config.toml"
  let manifest_path = root + "/manifest.toml"
  let acl_path = root + "/acl.txt"
  @fs.write_file(
    config_path,
    b"[security]\nallow_anonymous = true\n",
    create_mode=CreateNew,
    permission=0o600,
  )
  strict_reload_manifest(config_path, manifest_path, None)
  let first_bundle = @bundle.capture_bundle(manifest_path)
  let first_effective = first_bundle.evaluate(config_path, [])
  let first_fingerprint = first_bundle.policy_fingerprint(first_effective)
  let broker_config = @router.BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap()
  let snapshot : @router.BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "anonymous",
        owner_principal: "anonymous",
        detached_at_ms: 0L,
        next_packet_id: 1,
        subscriptions: [{ filter: "private/#", qos: 1 }],
        inbound_qos2: [],
        inflight: [],
        pending: [
          { topic: "private/one", payload: b"x", qos: 1, retain: false },
        ],
      },
    ],
    retained: [],
  }
  let broker = @router.BrokerState::from_snapshot(broker_config, snapshot).unwrap()
  broker.enable_policy_index().unwrap()
  let old_policy = @security.SecurityPolicy::permissive()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let runtime = BrokerRuntime::new(
    config,
    broker,
    security=old_policy,
    initial_policy_epoch=1L,
  )
  let handle = GenerationHandle::new(
    ConfigGeneration::initial(
      first_bundle,
      first_effective,
      old_policy,
      first_fingerprint,
      policy_epoch=1L,
    ),
  )
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(data_dir).unwrap(),
  ).unwrap()
  let store = @persistence.WalStore::bootstrap(lock, {
    generation: 1L,
    lsn: 0L,
    identities: [{ client_id: "anonymous", generation: 1L }],
    policy: Some({
      sequence: 1L,
      fingerprint: first_fingerprint,
      reconcile_pending: false,
    }),
    snapshot,
  }).unwrap()
  let writer = @persistence.WalWriter::new(store)
  let coordinator = CommitCoordinator::new(
    writer,
    broker.resource_ledger(),
    33554432L,
    1048576,
    1L,
    0L,
    broker~,
  ).unwrap()
  let client = @session.ClientId::new("anonymous").unwrap()
  let driver = RouterDriver::new(
    runtime,
    strict=coordinator,
    strict_generations=Map([(client, 1L)]),
    generation=handle,
  )
  @fs.write_file(
    acl_path,
    b"anonymous\ntopic read safe/#\n",
    create_mode=CreateNew,
    permission=0o600,
  )
  @fs.remove(config_path)
  let updated = "[security]\nallow_anonymous = true\nacl_file = \"" +
    acl_path +
    "\"\n"
  @fs.write_file(
    config_path,
    @utf8.encode(updated),
    create_mode=CreateNew,
    permission=0o600,
  )
  strict_reload_manifest(config_path, manifest_path, Some(acl_path))
  let limits = broker_config.resources()
  let pool = broker
    .resource_ledger()
    .pool(Infrastructure, limits.get("max_managed_bytes_total"))
    .unwrap()
  let prepared = match
    prepare_reload_candidate(
      manifest_path,
      config_path,
      [],
      first_bundle,
      first_effective,
      old_policy,
      pool,
      root,
      30000,
      16777216,
      67108864L,
    ) {
    ReloadPrepared(value) => value
    ReloadNoChange => fail("security change was missed")
  }
  assert_true(prepared.security_changed())
  let barrier_reply = @async.Queue(kind=Blocking(1))
  driver.handle(ReloadControl(ReloadEnterBarrier(barrier_reply)))
  assert_eq(barrier_reply.try_get(), Some(ReloadDriverReady))
  let reply = @async.Queue(kind=Blocking(2))
  driver.handle(ReloadControl(ReloadCommitPolicy(prepared, 0L, reply)))
  assert_eq(reply.try_get(), Some(ReloadDriverStaged))
  assert_eq(handle.active().config_epoch(), 0L)
  assert_eq(broker.subscription_count(), 1)
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    let mut activated = false
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      match reply.try_get() {
        Some(ReloadDriverActivated(1L, 2L)) => {
          activated = true
          break
        }
        Some(_) => fail("activation failed")
        None => ()
      }
      @async.sleep(1)
    }
    assert_true(activated)
    assert_eq(handle.active().config_epoch(), 1L)
    assert_eq(coordinator.policy_state().unwrap().sequence, 2L)
    let mut reconciled = false
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      if driver.reload_reconciler is None &&
        !coordinator.policy_state().unwrap().reconcile_pending {
        reconciled = true
        break
      }
      @async.sleep(1)
    }
    assert_true(reconciled)
    assert_eq(coordinator.committed_lsn(), 4L)
    assert_eq(broker.subscription_count(), 0)
    assert_eq(broker.pending_qos1_count(), 0)
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  handle.close()
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.remove(acl_path)
  @fs.rmdir(data_dir, recursive=true)
  @fs.rmdir(root)
}
