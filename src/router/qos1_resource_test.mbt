///|
test "qos1 broker configuration validates every new resource boundary" {
  assert_true(BrokerConfig::new(1, 1, 1, max_sessions=-1) is Err(_))
  assert_true(BrokerConfig::new(1, 1, 1, max_inflight_per_session=-1) is Err(_))
  assert_true(
    BrokerConfig::new(1, 1, 1, max_inflight_per_session=65536) is Err(_),
  )
  assert_true(BrokerConfig::new(1, 1, 1, max_inflight_total=-1) is Err(_))
  assert_true(
    BrokerConfig::new(1, 1, 1, max_pending_qos1_per_session=-1) is Err(_),
  )
  assert_true(BrokerConfig::new(1, 1, 1, max_pending_qos1_total=-1) is Err(_))
  let zero = BrokerConfig::new(
    0,
    0,
    0,
    max_sessions=0,
    max_inflight_per_session=0,
    max_inflight_total=0,
    max_pending_qos1_per_session=0,
    max_pending_qos1_total=0,
  ).unwrap()
  assert_eq(zero.max_sessions(), 0)
  assert_eq(zero.max_inflight_per_session(), 0)
  assert_eq(zero.max_inflight_total(), 0)
  assert_eq(zero.max_pending_qos1_per_session(), 0)
  assert_eq(zero.max_pending_qos1_total(), 0)
}

///|
test "session count limit rejects creation without partial state" {
  let config = BrokerConfig::new(1, 1, 1, max_sessions=1).unwrap()
  let state = BrokerState::new(config)
  let first = @session.ClientId::new("first").unwrap()
  let second = @session.ClientId::new("second").unwrap()
  ignore(state.apply(CreateSession(first)))
  assert_eq(
    state.apply(CreateSession(second)),
    Err(RouterError::SessionLimitReached(1)),
  )
  assert_eq(state.session_count(), 1)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "retained qos1 subscribe failure rolls back filters atomically" {
  let config = BrokerConfig::new(
    2,
    2,
    1,
    max_inflight_per_session=0,
    max_inflight_total=0,
    max_pending_qos1_per_session=0,
    max_pending_qos1_total=0,
  ).unwrap()
  let state = BrokerState::new(config)
  ignore(
    state.apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("retained/qos1").unwrap(),
        payload: b"saved",
        qos: @session.DeliveryQoS::QoS1,
        retain: true,
      }),
    ),
  )
  let client = @session.ClientId::new("subscriber").unwrap()
  ignore(state.apply(CreateSession(client)))
  let filter = @topic.TopicFilter::new("retained/#").unwrap()
  assert_true(
    state.apply(
      Subscribe({
        client_id: client,
        entries: [{ filter, qos: @session.DeliveryQoS::QoS1 }],
      }),
    )
    is Err(QoS1ResourceLimit(_, PendingQoS1PerSession)),
  )
  assert_eq(state.subscription_qos(client, filter), None)
  assert_eq(state.subscription_count(), 0)
  assert_eq(state.inflight_count(), 0)
  assert_eq(state.pending_qos1_count(), 0)
}

///|
test "internal qos1 resource drop isolates saturated recipient" {
  let config = BrokerConfig::new(
    1,
    2,
    0,
    max_inflight_per_session=0,
    max_inflight_total=0,
    max_pending_qos1_per_session=1,
    max_pending_qos1_total=1,
  ).unwrap()
  let state = BrokerState::new(config)
  let alice = @session.ClientId::new("alice").unwrap()
  let bob = @session.ClientId::new("bob").unwrap()
  let filter = @topic.TopicFilter::new("limited").unwrap()
  for client in [alice, bob] {
    ignore(
      state.apply(
        CreateSessionWith({
          client_id: client,
          mode: @session.SessionMode::Persistent,
          attached: false,
        }),
      ),
    )
    ignore(
      state.apply(
        Subscribe({
          client_id: client,
          entries: [{ filter, qos: @session.DeliveryQoS::QoS1 }],
        }),
      ),
    )
  }
  assert_eq(
    state.apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("limited").unwrap(),
        payload: b"one-recipient",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      }),
    ),
    Ok([DeliveryDroppedResourceLimit(bob)]),
  )
  assert_eq(state.session_pending_count(alice), Some(1))
  assert_eq(state.session_pending_count(bob), Some(0))
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "broker qos1 lifecycle remains invariant safe for 10000 events" {
  let config = BrokerConfig::new(
    1,
    1,
    0,
    max_inflight_per_session=1,
    max_inflight_total=1,
    max_pending_qos1_per_session=1,
    max_pending_qos1_total=1,
  ).unwrap()
  let state = BrokerState::new(config)
  let client = @session.ClientId::new("long-running").unwrap()
  ignore(state.apply(CreateSession(client)))
  ignore(
    state.apply(
      Subscribe({
        client_id: client,
        entries: [
          {
            filter: @topic.TopicFilter::new("long-running").unwrap(),
            qos: @session.DeliveryQoS::QoS1,
          },
        ],
      }),
    ),
  )
  for index in 0..<10000 {
    let delivery = match
      state
      .apply(
        Publish({
          origin: Internal,
          topic: @topic.TopicName::new("long-running").unwrap(),
          payload: @utf8.encode(index.to_string()),
          qos: @session.DeliveryQoS::QoS1,
          retain: false,
        }),
      )
      .unwrap()[0] {
      Deliver(value) => value
      _ => fail("publication must become inflight")
    }
    ignore(
      state.apply(
        Puback({ client_id: client, packet_id: delivery.packet_id.unwrap() }),
      ),
    )
  }
  assert_eq(state.inflight_count(), 0)
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}
