///|
async test "strict startup migrates policy WAL and reconciles before admission" {
  let path = "_build/server-reload-policy-bootstrap"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let broker_config = @router.BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap()
  let snapshot : @router.BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "deleted",
        owner_principal: "user:deleted",
        detached_at_ms: 0L,
        next_packet_id: 1,
        subscriptions: [{ filter: "private/#", qos: 1 }],
        inbound_qos2: [],
        inflight: [],
        pending: [],
      },
      {
        client_id: "anonymous",
        owner_principal: "anonymous",
        detached_at_ms: 0L,
        next_packet_id: 1,
        subscriptions: [
          { filter: "safe/#", qos: 1 },
          { filter: "private/#", qos: 1 },
        ],
        inbound_qos2: [],
        inflight: [],
        pending: [
          { topic: "safe/one", payload: b"a", qos: 1, retain: false },
          { topic: "private/two", payload: b"b", qos: 1, retain: false },
        ],
      },
    ],
    retained: [],
  }
  let broker = @router.BrokerState::from_snapshot(broker_config, snapshot).unwrap()
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let wal = @persistence.WalStore::bootstrap(lock, {
    generation: 1L,
    lsn: 0L,
    identities: [
      { client_id: "deleted", generation: 1L },
      { client_id: "anonymous", generation: 2L },
    ],
    policy: None,
    snapshot,
  }).unwrap()
  let acl = @security.AclPolicy::parse("anonymous\ntopic read safe/#\n").unwrap()
  let policy = @security.SecurityPolicy::new(acl~)
  let digest : Array[Byte] = []
  for _ in 0..<32 {
    digest.push(7)
  }
  let fingerprint = Bytes::from_array(digest)
  let started = bootstrap_strict_policy(
    wal,
    broker,
    [
      { client_id: "deleted", generation: 1L },
      { client_id: "anonymous", generation: 2L },
    ],
    policy,
    fingerprint,
    8,
    1048576L,
  )
  assert_true(wal.manifest().policy_required)
  assert_false(started.policy.reconcile_pending)
  assert_eq(broker.session_count(), 1)
  assert_eq(broker.subscription_count(), 1)
  assert_eq(broker.pending_qos1_count(), 1)
  assert_eq(broker.check_invariants(), Ok(()))
  wal.close()
  let second = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let limits = @persistence.SnapshotDecodeLimits::new(broker_config, 1024).unwrap()
  let (recovered, state) = @persistence.WalStore::recover_state(
    second, broker_config, limits,
  ).unwrap()
  assert_eq(state.policy().unwrap().fingerprint, fingerprint)
  assert_false(state.policy().unwrap().reconcile_pending)
  assert_eq(state.state().export_snapshot(), broker.export_snapshot())
  let other : Array[Byte] = []
  for _ in 0..<32 {
    other.push(8)
  }
  let mismatch = try {
    ignore(
      bootstrap_strict_policy(
        recovered,
        state.state(),
        state.identities(),
        policy,
        Bytes::from_array(other),
        8,
        1048576L,
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(mismatch)
  assert_eq(recovered.committed_lsn(), started.committed_lsn)
  let again = bootstrap_strict_policy(
    recovered,
    state.state(),
    state.identities(),
    policy,
    fingerprint,
    8,
    1048576L,
  )
  assert_eq(again.committed_lsn, started.committed_lsn)
  recovered.close()
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}
