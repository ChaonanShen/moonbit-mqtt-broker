///|
fn bytes_state(
  overrides : Array[(String, Int64)],
  inflight? : Int = 16,
) -> BrokerState {
  let mut resources = @budget.Limits::default()
  for entry in overrides {
    let (key, value) = entry
    resources = resources.with_value(key, value).unwrap()
  }
  BrokerState::new(
    BrokerConfig::new(
      32,
      128,
      32,
      resources~,
      max_inflight_per_session=inflight,
    ).unwrap(),
  )
}

///|
fn bytes_client(
  state : BrokerState,
  name : String,
  attached? : Bool = true,
) -> @session.ClientId {
  let client_id = @session.ClientId::new(name).unwrap()
  ignore(
    state
    .apply(CreateSessionWith({ client_id, mode: Persistent, attached }))
    .unwrap(),
  )
  client_id
}

///|
fn bytes_subscribe(
  state : BrokerState,
  client_id : @session.ClientId,
  filter : String,
) -> Array[BrokerAction] {
  state
  .apply(
    Subscribe({
      client_id,
      entries: [{ filter: @topic.TopicFilter::new(filter).unwrap(), qos: QoS2 }],
    }),
  )
  .unwrap()
}

///|
fn bytes_publish(
  state : BrokerState,
  id : @session.ClientId,
  topic : String,
  payload : Bytes,
  retain? : Bool = false,
) -> Result[Array[BrokerAction], RouterError] {
  state.apply(
    Publish({
      origin: Client(id),
      topic: @topic.TopicName::new(topic).unwrap(),
      payload,
      qos: QoS2,
      retain,
    }),
  )
}

///|
test "retained byte boundaries replacement deletion and failed admission preserve revision" {
  let state = bytes_state([("max_retained_bytes_total", 100L)])
  let id = bytes_client(state, "publisher")
  ignore(bytes_publish(state, id, "a", b"123", retain=true).unwrap())
  assert_eq(state.retained_bytes(), 100L)
  let before = state.export_snapshot()
  let revision = state.snapshot_revision()
  let bytes = state.managed_bytes()
  assert_true(
    bytes_publish(state, id, "a", b"1234", retain=true)
    is Err(ByteResourceLimit(_)),
  )
  assert_eq(state.export_snapshot(), before)
  assert_eq(state.snapshot_revision(), revision)
  assert_eq(state.managed_bytes(), bytes)
  ignore(bytes_publish(state, id, "a", b"1", retain=true).unwrap())
  assert_eq(state.retained_bytes(), 98L)
  ignore(bytes_publish(state, id, "a", b"", retain=true).unwrap())
  assert_eq(state.retained_bytes(), 0L)
}

///|
test "qos2 self fanout and inbound metadata reject atomically at one byte boundary" {
  let state = bytes_state([("max_session_state_bytes", 163L)])
  let id = bytes_client(state, "self")
  ignore(bytes_subscribe(state, id, "a"))
  let before = state.export_snapshot()
  let revision = state.snapshot_revision()
  let baseline = state.managed_bytes()
  assert_true(
    state.apply(
      ReceiveQoS2({
        client_id: id,
        packet_id: @session.SessionPacketId::new(1).unwrap(),
        publish: Some({
          origin: Client(id),
          topic: @topic.TopicName::new("a").unwrap(),
          payload: b"123",
          qos: QoS2,
          retain: true,
        }),
      }),
    )
    is Err(_),
  )
  assert_eq(state.export_snapshot(), before)
  assert_eq(state.managed_bytes(), baseline)
  assert_eq(state.snapshot_revision(), revision)
  assert_eq(state.inbound_qos2_count(), 0)
}

///|
test "global pending bytes reject all fanout targets and retained together" {
  let state = bytes_state([("max_pending_bytes_total", 199L)], inflight=0)
  let p = bytes_client(state, "p")
  for name in ["a", "z"] {
    let id = bytes_client(state, name, attached=false)
    ignore(bytes_subscribe(state, id, "t"))
  }
  let before = state.export_snapshot()
  let used = state.managed_bytes()
  assert_true(bytes_publish(state, p, "t", b"123", retain=true) is Err(_))
  assert_eq(state.export_snapshot(), before)
  assert_eq(state.managed_bytes(), used)
  assert_eq(state.pending_bytes(), 0L)
  assert_eq(state.retained_bytes(), 0L)
}

///|
test "subscription bytes fail individual SUBACK entries without orphan charges" {
  let state = bytes_state([("max_subscription_bytes_per_session", 65L)])
  let id = bytes_client(state, "s")
  let actions = state
    .apply(
      Subscribe({
        client_id: id,
        entries: [
          { filter: @topic.TopicFilter::new("a").unwrap(), qos: QoS1 },
          { filter: @topic.TopicFilter::new("b").unwrap(), qos: QoS1 },
        ],
      }),
    )
    .unwrap()
  assert_eq(actions, [
    SubscriptionsApplied({
      client_id: id,
      results: [Granted(QoS1), RejectedLimit(Bytes)],
    }),
  ])
  assert_eq(state.subscription_count(), 1)
  ignore(state.apply(RemoveSession(id)).unwrap())
  assert_eq(state.managed_bytes(), 0L)
}

///|
test "PUBREC releases payload keeps slot and PUBCOMP releases metadata once" {
  let state = bytes_state([])
  let id = bytes_client(state, "subscriber")
  ignore(bytes_subscribe(state, id, "t"))
  let baseline = state.managed_bytes()
  let actions = bytes_publish(state, id, "t", b"123").unwrap()
  let pid = match actions[0] {
    Deliver(d) => d.packet_id.unwrap()
    _ => fail("expected delivery")
  }
  assert_eq(state.inflight_bytes(), 100L)
  ignore(state.apply(Pubrec({ client_id: id, packet_id: pid })).unwrap())
  assert_eq(state.inflight_bytes(), 64L)
  assert_eq(state.inflight_count(), 1)
  ignore(state.apply(Pubrec({ client_id: id, packet_id: pid })).unwrap())
  assert_eq(state.inflight_bytes(), 64L)
  ignore(state.apply(Pubcomp({ client_id: id, packet_id: pid })).unwrap())
  ignore(state.apply(Pubcomp({ client_id: id, packet_id: pid })).unwrap())
  assert_eq(state.managed_bytes(), baseline)
}

///|
test "large existing backlog consumes scratch before a tiny new delivery is copied" {
  let state = bytes_state([("max_routing_scratch_bytes", 2100L)], inflight=0)
  let id = bytes_client(state, "s", attached=false)
  ignore(bytes_subscribe(state, id, "t"))
  for _ in 0..<6 {
    ignore(bytes_publish(state, id, "t", b"123").unwrap())
  }
  let before = state.export_snapshot()
  let used = state.managed_bytes()
  assert_true(
    bytes_publish(state, id, "t", b"123") is Err(ByteResourceLimit(_)),
  )
  assert_eq(state.export_snapshot(), before)
  assert_eq(state.managed_bytes(), used)
}

///|
test "snapshot restore recomputes byte charges and rejects lower limits atomically" {
  let state = bytes_state([])
  let id = bytes_client(state, "persist", attached=false)
  ignore(bytes_subscribe(state, id, "t"))
  ignore(bytes_publish(state, id, "t", b"123", retain=true).unwrap())
  let snapshot = state.export_snapshot()
  let restored = BrokerState::from_snapshot(state.config(), snapshot).unwrap()
  assert_eq(restored.managed_bytes(), state.managed_bytes())
  assert_eq(restored.export_snapshot(), snapshot)
  let resources = @budget.Limits::default()
    .with_value("max_pending_bytes_total", 99L)
    .unwrap()
  let cfg = BrokerConfig::new(32, 128, 32, resources~).unwrap()
  assert_true(
    BrokerState::from_snapshot(cfg, snapshot)
    is Err(SnapshotError::LimitExceeded(_)),
  )
  assert_eq(state.export_snapshot(), snapshot)
}

///|
test "freeing global inflight bytes wakes another session with no inflight of its own" {
  let state = bytes_state([("max_inflight_bytes_total", 100L)])
  let a = bytes_client(state, "a")
  let b = bytes_client(state, "b")
  ignore(bytes_subscribe(state, a, "a"))
  ignore(bytes_subscribe(state, b, "b"))
  let first = bytes_publish(state, a, "a", b"123").unwrap()
  let pid = match first[0] {
    Deliver(d) => d.packet_id.unwrap()
    _ => fail("expected first")
  }
  assert_eq(bytes_publish(state, a, "b", b"123"), Ok([]))
  assert_eq(state.session_inflight_count(b), Some(0))
  assert_eq(state.session_pending_count(b), Some(1))
  ignore(state.apply(Pubrec({ client_id: a, packet_id: pid })).unwrap())
  let completed = state
    .apply(Pubcomp({ client_id: a, packet_id: pid }))
    .unwrap()
  assert_true(
    completed.any(action => {
      action is Deliver({ recipient, .. }) && recipient == b
    }),
  )
  assert_eq(state.session_inflight_count(b), Some(1))
  assert_eq(state.session_pending_count(b), Some(0))
  assert_eq(state.inflight_bytes(), 100L)
}
