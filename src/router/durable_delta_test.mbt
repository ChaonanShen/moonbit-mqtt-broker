///|
fn durable_test_config() -> BrokerConfig {
  BrokerConfig::new(4, 16, 8, max_sessions=8).unwrap()
}

///|
fn durable_test_session() -> SnapshotSessionV3 {
  {
    client_id: "client-a",
    owner_principal: "anonymous",
    detached_at_ms: 0L,
    next_packet_id: 1,
    subscriptions: [],
    inbound_qos2: [],
    inflight: [],
    pending: [],
  }
}

///|
test "durable delta applies affected keys and preserves generation" {
  let initial : BrokerSnapshotV3 = {
    version: 3,
    sessions: [durable_test_session()],
    retained: [],
  }
  let state = DurableAccumulator::new(durable_test_config(), initial, [5L]).unwrap()
  let updated = {
    ..durable_test_session(),
    subscriptions: [{ filter: "state/#", qos: 1 }],
  }
  let delta : DurableDelta = {
    session_puts: [
      { expected_generation: 5L, generation: 5L, session: updated },
    ],
    session_deletes: [],
    retained_puts: [{ topic: "state/value", payload: b"on", qos: 1 }],
    retained_deletes: [],
  }
  assert_eq(state.apply(delta), Ok(()))
  let (snapshot, generations) = state.export_snapshot()
  assert_eq(generations, [5L])
  assert_eq(snapshot.sessions[0], updated)
  assert_eq(snapshot.retained[0].payload, b"on")
}

///|
test "durable delta validates every key before applying any change" {
  let initial : BrokerSnapshotV3 = {
    version: 3,
    sessions: [durable_test_session()],
    retained: [],
  }
  let state = DurableAccumulator::new(durable_test_config(), initial, [5L]).unwrap()
  let before = state.export_snapshot()
  let invalid : DurableDelta = {
    session_puts: [],
    session_deletes: [{ client_id: "client-a", expected_generation: 4L }],
    retained_puts: [{ topic: "state/value", payload: b"on", qos: 1 }],
    retained_deletes: [],
  }
  assert_true(state.apply(invalid) is Err(InvalidState(_)))
  assert_eq(state.export_snapshot(), before)
}

///|
test "durable session generation prevents stale delete after replacement" {
  let initial : BrokerSnapshotV3 = {
    version: 3,
    sessions: [durable_test_session()],
    retained: [],
  }
  let state = DurableAccumulator::new(durable_test_config(), initial, [5L]).unwrap()
  let replacement : DurableDelta = {
    session_puts: [
      {
        expected_generation: 5L,
        generation: 6L,
        session: durable_test_session(),
      },
    ],
    session_deletes: [],
    retained_puts: [],
    retained_deletes: [],
  }
  assert_eq(state.apply(replacement), Ok(()))
  let stale : DurableDelta = {
    session_puts: [],
    session_deletes: [{ client_id: "client-a", expected_generation: 5L }],
    retained_puts: [],
    retained_deletes: [],
  }
  assert_true(state.apply(stale) is Err(InvalidState(_)))
  assert_eq(state.export_snapshot().1, [6L])
}

///|
test "local policy delta drops one subscription and pending head" {
  let initial : BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        ..durable_test_session(),
        subscriptions: [
          { filter: "safe/#", qos: 1 },
          { filter: "private/#", qos: 1 },
        ],
        pending: [
          { topic: "private/one", payload: b"a", qos: 1, retain: false },
          { topic: "safe/two", payload: b"b", qos: 1, retain: false },
        ],
      },
    ],
    retained: [],
  }
  let state = DurableAccumulator::new(durable_test_config(), initial, [5L]).unwrap()
  assert_eq(
    state.apply_reconcile({
      client_id: "client-a",
      expected_generation: 5L,
      change: DropSubscription("private/#"),
    }),
    Ok(()),
  )
  assert_eq(
    state.apply_reconcile({
      client_id: "client-a",
      expected_generation: 5L,
      change: DropPendingHead("private/one", 1, 1),
    }),
    Ok(()),
  )
  let (snapshot, generations) = state.export_snapshot()
  assert_eq(generations, [5L])
  assert_eq(snapshot.sessions[0].subscriptions, [{ filter: "safe/#", qos: 1 }])
  assert_eq(snapshot.sessions[0].pending.length(), 1)
  assert_eq(snapshot.sessions[0].pending[0].topic, "safe/two")
  let before = state.export_snapshot()
  assert_true(
    state.apply_reconcile({
      client_id: "client-a",
      expected_generation: 4L,
      change: DropPendingHead("safe/two", 1, 1),
    })
    is Err(_),
  )
  assert_eq(state.export_snapshot(), before)
}
