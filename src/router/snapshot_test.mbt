///|
fn snapshot_config() -> BrokerConfig {
  BrokerConfig::new(
    4,
    16,
    8,
    max_sessions=8,
    max_inflight_per_session=2,
    max_inflight_total=4,
    max_pending_qos1_per_session=4,
    max_pending_qos1_total=8,
  ).unwrap()
}

///|
fn snapshot_client(value : String) -> @session.ClientId {
  @session.ClientId::new(value).unwrap()
}

///|
fn snapshot_topic(value : String) -> @topic.TopicName {
  @topic.TopicName::new(value).unwrap()
}

///|
fn snapshot_filter(value : String) -> @topic.TopicFilter {
  @topic.TopicFilter::new(value).unwrap()
}

///|
test "snapshot roundtrip preserves persistent qos1 state" {
  let config = snapshot_config()
  let state = BrokerState::new(config)
  let persistent = snapshot_client("persistent")
  let clean = snapshot_client("clean")
  ignore(
    state.apply(
      CreateSessionWith({
        client_id: persistent,
        mode: @session.SessionMode::Persistent,
        attached: true,
      }),
    ),
  )
  ignore(state.apply(CreateSession(clean)))
  ignore(
    state.apply(
      Subscribe({
        client_id: persistent,
        entries: [
          {
            filter: snapshot_filter("state/#"),
            qos: @session.DeliveryQoS::QoS1,
          },
        ],
      }),
    ),
  )
  ignore(
    state.apply(
      Publish({
        origin: Internal,
        topic: snapshot_topic("state/inflight"),
        payload: b"inflight",
        qos: @session.DeliveryQoS::QoS1,
        retain: true,
      }),
    ),
  )
  ignore(state.apply(DetachSession(persistent)))
  ignore(
    state.apply(
      Publish({
        origin: Internal,
        topic: snapshot_topic("state/pending"),
        payload: b"pending",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      }),
    ),
  )
  let exported = state.export_snapshot()
  assert_eq(exported.version, 1)
  assert_eq(exported.sessions.length(), 1)
  assert_eq(exported.sessions[0].client_id, "persistent")
  assert_eq(exported.sessions[0].inflight[0].message.payload, b"inflight")
  assert_eq(exported.sessions[0].pending[0].payload, b"pending")
  assert_eq(exported.retained.length(), 1)
  let restored = BrokerState::from_snapshot(config, exported).unwrap()
  assert_eq(restored.session_attached(persistent), Some(false))
  assert_eq(restored.session_inflight_count(persistent), Some(1))
  assert_eq(restored.session_pending_count(persistent), Some(1))
  assert_eq(restored.export_snapshot(), exported)
  assert_eq(restored.check_invariants(), Ok(()))

  exported.sessions.clear()
  exported.retained.clear()
  assert_eq(restored.export_snapshot().sessions.length(), 1)
  assert_eq(restored.export_snapshot().retained.length(), 1)
}

///|
test "snapshot import rejects corruption without partial state" {
  let config = snapshot_config()
  let empty : BrokerSnapshotV1 = { version: 1, sessions: [], retained: [] }
  assert_true(
    BrokerState::from_snapshot(config, { ..empty, version: 2 })
    is Err(SnapshotError::UnsupportedVersion(2)),
  )
  let duplicate_session : SnapshotSessionV1 = {
    client_id: "duplicate",
    next_packet_id: 1,
    subscriptions: [],
    inflight: [],
    pending: [],
  }
  assert_true(
    BrokerState::from_snapshot(config, {
      version: 1,
      sessions: [duplicate_session, duplicate_session],
      retained: [],
    })
    is Err(SnapshotError::DuplicateSession("duplicate")),
  )
  let duplicate_id : SnapshotSessionV1 = {
    client_id: "ids",
    next_packet_id: 2,
    subscriptions: [],
    inflight: [
      {
        packet_id: 1,
        message: { topic: "valid", payload: b"a", retain: false },
      },
      {
        packet_id: 1,
        message: { topic: "valid", payload: b"b", retain: false },
      },
    ],
    pending: [],
  }
  assert_true(
    BrokerState::from_snapshot(config, {
      version: 1,
      sessions: [duplicate_id],
      retained: [],
    })
    is Err(SnapshotError::InvalidState("duplicate inflight packet id")),
  )
  let invalid_topic : BrokerSnapshotV1 = {
    version: 1,
    sessions: [],
    retained: [{ topic: "bad/+", payload: b"x", qos: 1 }],
  }
  assert_true(
    BrokerState::from_snapshot(config, invalid_topic)
    is Err(SnapshotError::InvalidTopic("bad/+")),
  )
  assert_eq(
    BrokerState::from_snapshot(config, empty).unwrap().session_count(),
    0,
  )
}

///|
test "snapshot export is deterministic across insertion order" {
  let config = snapshot_config()
  let left = BrokerState::new(config)
  let right = BrokerState::new(config)
  for name in ["zeta", "alpha"] {
    ignore(
      left.apply(
        CreateSessionWith({
          client_id: snapshot_client(name),
          mode: @session.SessionMode::Persistent,
          attached: false,
        }),
      ),
    )
  }
  for name in ["alpha", "zeta"] {
    ignore(
      right.apply(
        CreateSessionWith({
          client_id: snapshot_client(name),
          mode: @session.SessionMode::Persistent,
          attached: false,
        }),
      ),
    )
  }
  assert_eq(left.export_snapshot(), right.export_snapshot())
  assert_eq(left.export_snapshot().sessions[0].client_id, "alpha")
}
