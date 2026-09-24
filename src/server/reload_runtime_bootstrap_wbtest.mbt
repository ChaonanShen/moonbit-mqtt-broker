///|
async test "snapshot startup removes denied backlog before admission" {
  let broker_config = @router.BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap()
  let snapshot : @router.BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "removed",
        owner_principal: "user:removed",
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
  let acl = @security.AclPolicy::parse("anonymous\ntopic read safe/#\n").unwrap()
  let policy = @security.SecurityPolicy::new(acl~)
  bootstrap_runtime_policy(broker, policy, 1L, 8, 1048576L)
  assert_eq(broker.session_count(), 1)
  assert_eq(broker.subscription_count(), 1)
  assert_eq(broker.pending_qos1_count(), 1)
  assert_eq(broker.export_snapshot().sessions[0].pending[0].topic, "safe/one")
  let revision = broker.snapshot_revision()
  bootstrap_runtime_policy(broker, policy, 1L, 8, 1048576L)
  assert_eq(broker.snapshot_revision(), revision)
  assert_eq(broker.check_invariants(), Ok(()))
}
