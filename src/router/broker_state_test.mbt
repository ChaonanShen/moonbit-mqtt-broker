///|
fn state_client(value : String) -> @session.ClientId {
  @session.ClientId::new(value).unwrap()
}

///|
fn state_topic(value : String) -> @topic.TopicName {
  @topic.TopicName::new(value).unwrap()
}

///|
fn state_filter(value : String) -> @topic.TopicFilter {
  @topic.TopicFilter::new(value).unwrap()
}

///|
fn config() -> BrokerConfig {
  BrokerConfig::new(2, 4, 2).unwrap()
}

///|
test "broker routes once at combined qos and retains replay after acknowledgement" {
  let state = BrokerState::new(config())
  let alice = state_client("alice")
  let bob = state_client("bob")
  assert_eq(
    state.apply(BrokerEvent::CreateSession(alice)),
    Ok([BrokerAction::SessionCreated(alice)]),
  )
  assert_eq(
    state.apply(BrokerEvent::CreateSession(bob)),
    Ok([BrokerAction::SessionCreated(bob)]),
  )
  let subscribe = BrokerEvent::Subscribe({
    client_id: bob,
    entries: [
      { filter: state_filter("sensors/#"), qos: @session.DeliveryQoS::QoS0 },
      { filter: state_filter("sensors/temp"), qos: @session.DeliveryQoS::QoS1 },
    ],
  })
  assert_eq(
    state.apply(subscribe),
    Ok([
      BrokerAction::SubscriptionsApplied({
        client_id: bob,
        results: [
          SubscribeResult::Granted(@session.DeliveryQoS::QoS0),
          SubscribeResult::Granted(@session.DeliveryQoS::QoS1),
        ],
      }),
    ]),
  )
  let input : PublishInput = {
    origin: PublishOrigin::Client(alice),
    topic: state_topic("sensors/temp"),
    payload: b"22",
    qos: @session.DeliveryQoS::QoS1,
    retain: true,
  }
  assert_eq(
    state.apply(BrokerEvent::Publish(input)),
    Ok([
      BrokerAction::Deliver({
        recipient: bob,
        topic: state_topic("sensors/temp"),
        payload: b"22",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      }),
    ]),
  )
  let carol = state_client("carol")
  ignore(state.apply(BrokerEvent::CreateSession(carol)))
  let replay = state
    .apply(
      BrokerEvent::Subscribe({
        client_id: carol,
        entries: [
          { filter: state_filter("sensors/#"), qos: @session.DeliveryQoS::QoS1 },
        ],
      }),
    )
    .unwrap()
  assert_eq(
    replay[0],
    BrokerAction::SubscriptionsApplied({
      client_id: carol,
      results: [SubscribeResult::Granted(@session.DeliveryQoS::QoS1)],
    }),
  )
  assert_eq(
    replay[1],
    BrokerAction::Deliver({
      recipient: carol,
      topic: state_topic("sensors/temp"),
      payload: b"22",
      qos: @session.DeliveryQoS::QoS1,
      retain: true,
    }),
  )
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "retained capacity rejection is atomic and unsubscribe is idempotent" {
  let state = BrokerState::new(BrokerConfig::new(1, 1, 0).unwrap())
  let client = state_client("client")
  ignore(state.apply(BrokerEvent::CreateSession(client)))
  let first = state
    .apply(
      BrokerEvent::Subscribe({
        client_id: client,
        entries: [
          { filter: state_filter("a"), qos: @session.DeliveryQoS::QoS0 },
        ],
      }),
    )
    .unwrap()
  assert_eq(first.length(), 1)
  let publish : PublishInput = {
    origin: PublishOrigin::Internal,
    topic: state_topic("a"),
    payload: b"x",
    qos: @session.DeliveryQoS::QoS0,
    retain: true,
  }
  assert_eq(
    state.apply(BrokerEvent::Publish(publish)),
    Err(RouterError::RetainedLimitReached(0)),
  )
  assert_eq(state.retained_count(), 0)
  assert_eq(
    state.apply(
      BrokerEvent::Unsubscribe({
        client_id: client,
        filters: [state_filter("a"), state_filter("a")],
      }),
    ),
    Ok([
      BrokerAction::UnsubscriptionsApplied({
        client_id: client,
        removed: [true, false],
      }),
    ]),
  )
}
