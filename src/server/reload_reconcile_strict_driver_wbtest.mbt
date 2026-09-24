///|
async test "strict driver finishes incremental policy cleanup and WAL completion marker" {
  let root = @fs.tmpdir(prefix="mqtt-reload-strict-scan-")
  let data_dir = root + "/state"
  let config_path = root + "/config.toml"
  let manifest_path = root + "/manifest.toml"
  @fs.write_file(
    config_path,
    b"[security]\nallow_anonymous = true\n",
    create_mode=CreateNew,
    permission=0o600,
  )
  let (hash_status, hash_output, _) = @process.collect_output("sha256sum", [
    config_path,
  ])
  assert_eq(hash_status, 0)
  let digest_text = hash_output.text().split(" ").to_array()[0].to_owned()
  let manifest_text = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"" +
    digest_text +
    "\"\n"
  @fs.write_file(
    manifest_path,
    @utf8.encode(manifest_text),
    create_mode=CreateNew,
    permission=0o600,
  )
  let bundle = @bundle.capture_bundle(manifest_path)
  let effective = bundle.evaluate(config_path, [])
  let broker_config = @router.BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap()
  let snapshot : @router.BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "client-a",
        owner_principal: "anonymous",
        detached_at_ms: 0L,
        next_packet_id: 1,
        subscriptions: [{ filter: "private/#", qos: 1 }],
        inbound_qos2: [],
        inflight: [],
        pending: [
          { topic: "private/value", payload: b"x", qos: 1, retain: false },
        ],
      },
    ],
    retained: [],
  }
  let broker = @router.BrokerState::from_snapshot(broker_config, snapshot).unwrap()
  broker.enable_policy_index().unwrap()
  let policy = @security.SecurityPolicy::new(
    acl=@security.AclPolicy::parse("").unwrap(),
  )
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let runtime = BrokerRuntime::new(
    config,
    broker,
    security=policy,
    initial_policy_epoch=1L,
  )
  let fingerprint = Bytes::from_array(Array::make(32, 8))
  let handle = GenerationHandle::new(
    ConfigGeneration::initial(
      bundle,
      effective,
      policy,
      fingerprint,
      policy_epoch=1L,
    ),
  )
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(data_dir).unwrap(),
  ).unwrap()
  let store = @persistence.WalStore::bootstrap(lock, {
    generation: 1L,
    lsn: 0L,
    identities: [{ client_id: "client-a", generation: 1L }],
    policy: Some({ sequence: 1L, fingerprint, reconcile_pending: true }),
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
  let client = @session.ClientId::new("client-a").unwrap()
  let driver = RouterDriver::new(
    runtime,
    strict=coordinator,
    strict_generations=Map([(client, 1L)]),
    generation=handle,
  )
  driver.reload_reconciler = Some(
    @router.PolicyReconciler::new(policy, 1L, 8, 1048576L).unwrap(),
  )
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    let mut finished = false
    for _ in 0..<1000 {
      driver.handle(WalCompletionDue)
      if driver.reload_reconciler is None {
        finished = true
        break
      }
      @async.sleep(1)
    }
    assert_true(finished)
    assert_eq(coordinator.committed_lsn(), 3L)
    assert_false(coordinator.policy_state().unwrap().reconcile_pending)
    assert_eq(broker.subscription_count(), 0)
    assert_eq(broker.pending_qos1_count(), 0)
    assert_eq(broker.check_invariants(), Ok(()))
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  handle.close()
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.rmdir(data_dir, recursive=true)
  @fs.rmdir(root)
}
