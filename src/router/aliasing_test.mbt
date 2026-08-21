///|
fn alias_client(value : String) -> @session.ClientId {
  @session.ClientId::new(value).unwrap()
}

///|
fn alias_filter(value : String) -> @topic.TopicFilter {
  @topic.TopicFilter::new(value).unwrap()
}

///|
fn alias_topic(value : String) -> @topic.TopicName {
  @topic.TopicName::new(value).unwrap()
}

///|
test "router containers do not alias caller state" {
  let state = BrokerState::new(BrokerConfig::new(3, 3, 3).unwrap())
  let client = alias_client("client")
  ignore(state.apply(BrokerEvent::CreateSession(client)))
  let entries : Array[SubscribeEntry] = [
    { filter: alias_filter("a/#"), qos: @session.DeliveryQoS::QoS1 },
  ]
  let event = BrokerEvent::Subscribe({ client_id: client, entries })
  ignore(state.apply(event))
  entries.clear()
  entries.push({
    filter: alias_filter("other"),
    qos: @session.DeliveryQoS::QoS0,
  })
  assert_eq(
    state.subscription_qos(client, alias_filter("a/#")),
    Some(@session.DeliveryQoS::QoS1),
  )
  assert_eq(state.subscription_qos(client, alias_filter("other")), None)

  let index = SubscriptionIndex::new()
  ignore(index.put(client, alias_filter("a/#"), @session.DeliveryQoS::QoS1))
  let matches = index.matches(alias_topic("a/x"))
  matches.clear()
  assert_eq(index.matches(alias_topic("a/x")).length(), 1)

  let source : Array[Byte] = [0x61, 0x62, 0x63]
  let payload = Bytes::from_array(source)
  ignore(
    state.apply(
      BrokerEvent::Publish({
        origin: PublishOrigin::Internal,
        topic: alias_topic("a/x"),
        payload,
        qos: @session.DeliveryQoS::QoS1,
        retain: true,
      }),
    ),
  )
  source[0] = 0x7a
  assert_eq(state.retained_message(alias_topic("a/x")).unwrap().payload, b"abc")

  let exported = state.retained_message(alias_topic("a/x")).unwrap().payload.to_array()
  exported[0] = 0x7a
  assert_eq(state.retained_message(alias_topic("a/x")).unwrap().payload, b"abc")

  let store = RetainedStore::new()
  ignore(
    store.put(alias_topic("stored"), b"value", @session.DeliveryQoS::QoS0, 1),
  )
  let retained_matches = store.matching([alias_filter("#")])
  retained_matches.clear()
  assert_eq(store.count(), 1)

  let actions = state
    .apply(
      BrokerEvent::Publish({
        origin: PublishOrigin::Internal,
        topic: alias_topic("a/x"),
        payload: b"live",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      }),
    )
    .unwrap()
  match actions[0] {
    BrokerAction::Deliver(delivery) => {
      let mutable = delivery.payload.to_array()
      mutable[0] = 0x78
    }
    _ => fail("expected delivery")
  }
  assert_eq(state.retained_message(alias_topic("a/x")).unwrap().payload, b"abc")
  assert_eq(state.check_invariants(), Ok(()))
}
