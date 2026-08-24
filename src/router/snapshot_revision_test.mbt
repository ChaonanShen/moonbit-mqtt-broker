///|
fn revision_client(value : String) -> @session.ClientId {
  @session.ClientId::new(value).unwrap()
}

///|
fn revision_topic(value : String) -> @topic.TopicName {
  @topic.TopicName::new(value).unwrap()
}

///|
fn revision_filter(value : String) -> @topic.TopicFilter {
  @topic.TopicFilter::new(value).unwrap()
}

///|
fn revision_state() -> BrokerState {
  BrokerState::new(
    BrokerConfig::new(
      8,
      32,
      16,
      max_sessions=8,
      max_inflight_per_session=2,
      max_inflight_total=8,
      max_pending_qos1_per_session=8,
      max_pending_qos1_total=16,
    ).unwrap(),
  )
}

///|
fn assert_revision_contract(
  state : BrokerState,
  event : BrokerEvent,
) -> Array[BrokerAction] raise {
  let before_snapshot = state.export_snapshot()
  let before_revision = state.snapshot_revision()
  let actions = state.apply(event).unwrap()
  let after_snapshot = state.export_snapshot()
  let after_revision = state.snapshot_revision()
  if after_snapshot != before_snapshot {
    assert_true(after_revision > before_revision)
  } else {
    assert_eq(after_revision, before_revision)
  }
  actions
}

///|
test "snapshot revision tracks persistent session and subscription changes" {
  let state = revision_state()
  let persistent = revision_client("persistent")
  let clean = revision_client("clean")
  ignore(
    assert_revision_contract(
      state,
      CreateSessionWith({
        client_id: persistent,
        mode: @session.SessionMode::Persistent,
        attached: true,
      }),
    ),
  )
  let after_persistent = state.snapshot_revision()
  ignore(assert_revision_contract(state, CreateSession(clean)))
  assert_eq(state.snapshot_revision(), after_persistent)
  let filter = revision_filter("revision/#")
  ignore(
    assert_revision_contract(
      state,
      Subscribe({
        client_id: persistent,
        entries: [{ filter, qos: @session.DeliveryQoS::QoS1 }],
      }),
    ),
  )
  let after_subscribe = state.snapshot_revision()
  ignore(
    assert_revision_contract(
      state,
      Subscribe({
        client_id: persistent,
        entries: [{ filter, qos: @session.DeliveryQoS::QoS1 }],
      }),
    ),
  )
  assert_eq(state.snapshot_revision(), after_subscribe)
  ignore(
    assert_revision_contract(
      state,
      Unsubscribe({ client_id: persistent, filters: [filter] }),
    ),
  )
  let after_unsubscribe = state.snapshot_revision()
  ignore(
    assert_revision_contract(
      state,
      Unsubscribe({ client_id: persistent, filters: [filter] }),
    ),
  )
  assert_eq(state.snapshot_revision(), after_unsubscribe)
  ignore(assert_revision_contract(state, RemoveSession(clean)))
  ignore(assert_revision_contract(state, RemoveSession(persistent)))
}

///|
test "snapshot revision tracks retained inflight pending ack and packet ids" {
  let state = revision_state()
  let client = revision_client("qos1")
  let topic = revision_topic("revision/value")
  ignore(
    assert_revision_contract(
      state,
      CreateSessionWith({
        client_id: client,
        mode: @session.SessionMode::Persistent,
        attached: true,
      }),
    ),
  )
  ignore(
    assert_revision_contract(
      state,
      Subscribe({
        client_id: client,
        entries: [
          {
            filter: revision_filter("revision/#"),
            qos: @session.DeliveryQoS::QoS1,
          },
        ],
      }),
    ),
  )
  let actions = assert_revision_contract(
    state,
    Publish({
      origin: Internal,
      topic,
      payload: b"one",
      qos: @session.DeliveryQoS::QoS1,
      retain: true,
    }),
  )
  let packet_id = match actions[0] {
    Deliver(delivery) => delivery.packet_id.unwrap()
    _ => fail("expected qos1 delivery")
  }
  let unchanged = state.snapshot_revision()
  ignore(
    assert_revision_contract(
      state,
      Publish({
        origin: Internal,
        topic,
        payload: b"one",
        qos: @session.DeliveryQoS::QoS1,
        retain: true,
      }),
    ),
  )
  // The second publish still changes inflight even though retained is identical.
  assert_true(state.snapshot_revision() > unchanged)
  ignore(
    assert_revision_contract(state, Puback({ client_id: client, packet_id })),
  )
  let after_ack = state.snapshot_revision()
  ignore(
    assert_revision_contract(state, Puback({ client_id: client, packet_id })),
  )
  assert_eq(state.snapshot_revision(), after_ack)
  ignore(assert_revision_contract(state, DetachSession(client)))
  ignore(
    assert_revision_contract(
      state,
      Publish({
        origin: Internal,
        topic,
        payload: b"offline",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      }),
    ),
  )
  ignore(assert_revision_contract(state, AttachSession(client)))
  ignore(
    assert_revision_contract(
      state,
      Publish({
        origin: Internal,
        topic,
        payload: b"",
        qos: @session.DeliveryQoS::QoS0,
        retain: true,
      }),
    ),
  )
}

///|
test "snapshot revision ignores clean sessions and rejected transitions" {
  let state = revision_state()
  let clean = revision_client("clean-only")
  ignore(assert_revision_contract(state, CreateSession(clean)))
  ignore(
    assert_revision_contract(
      state,
      Subscribe({
        client_id: clean,
        entries: [
          {
            filter: revision_filter("clean/#"),
            qos: @session.DeliveryQoS::QoS1,
          },
        ],
      }),
    ),
  )
  ignore(
    assert_revision_contract(
      state,
      Publish({
        origin: Internal,
        topic: revision_topic("clean/value"),
        payload: b"ephemeral",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      }),
    ),
  )
  assert_eq(state.snapshot_revision(), 0L)
  let before = state.snapshot_revision()
  assert_true(
    state.apply(Subscribe({ client_id: clean, entries: [] })) is Err(_),
  )
  assert_eq(state.snapshot_revision(), before)
}

///|
test "restored snapshot revision starts at zero" {
  let config = revision_state().config()
  let restored = BrokerState::from_snapshot(config, {
    version: 1,
    sessions: [
      {
        client_id: "restored",
        next_packet_id: 7,
        subscriptions: [],
        inflight: [],
        pending: [],
      },
    ],
    retained: [{ topic: "restored/value", payload: b"x", qos: 0 }],
  }).unwrap()
  assert_eq(restored.snapshot_revision(), 0L)
}

///|
test "clean sessions are absent from disk snapshot" {
  let state = revision_state()
  let clean = revision_client("not-on-disk")
  ignore(state.apply(CreateSession(clean)))
  ignore(
    state.apply(
      Subscribe({
        client_id: clean,
        entries: [
          {
            filter: revision_filter("not-on-disk/#"),
            qos: @session.DeliveryQoS::QoS1,
          },
        ],
      }),
    ),
  )
  assert_eq(state.export_snapshot().sessions, [])
}
