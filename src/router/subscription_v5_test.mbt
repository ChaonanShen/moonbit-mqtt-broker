///|
test "C-T12 MQTT5 Retain Handling and shared rejection" {
  let state = BrokerState::new(BrokerConfig::new(8, 16, 8).unwrap())
  let publisher = @session.ClientId::new("publisher").unwrap()
  let subscriber = @session.ClientId::new("subscriber").unwrap()
  ignore(state.apply(CreateSession(publisher)))
  ignore(state.apply(CreateSession(subscriber)))
  let topic = @topic.TopicName::new("retained/a").unwrap()
  ignore(
    state
    .apply(
      Publish({
        origin: Client(publisher),
        topic,
        payload: b"saved",
        qos: @session.QoS1,
        retain: true,
      }),
    )
    .unwrap(),
  )
  let entry : SubscribeEntryV5 = {
    filter: @topic.TopicFilter::new("retained/#").unwrap(),
    qos: @session.QoS1,
    no_local: false,
    retain_as_published: false,
    retain_handling: 2,
    subscription_identifier: Some(7),
  }
  let first = state
    .apply(SubscribeV5({ client_id: subscriber, entries: [entry] }))
    .unwrap()
  assert_eq(first.length(), 1)
  let second = state
    .apply(
      SubscribeV5({
        client_id: subscriber,
        entries: [{ ..entry, retain_handling: 1 }],
      }),
    )
    .unwrap()
  assert_eq(second.length(), 1)
  let third = state
    .apply(
      SubscribeV5({
        client_id: subscriber,
        entries: [
          {
            ..entry,
            filter: @topic.TopicFilter::new("retained/+").unwrap(),
            retain_handling: 1,
          },
        ],
      }),
    )
    .unwrap()
  assert_true(third.any(action => action is DeliverWithMetadata(_)))
  let rejected = state
    .apply(
      SubscribeV5({
        client_id: subscriber,
        entries: [
          {
            ..entry,
            filter: @topic.TopicFilter::new("$share/g/retained/#").unwrap(),
          },
        ],
      }),
    )
    .unwrap()
  assert_eq(
    rejected[0],
    SubscriptionsApplied({
      client_id: subscriber,
      results: [RejectedSharedUnsupported],
    }),
  )
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "C-T12 duplicate subscription IDs remain ordered on one delivery" {
  let state = BrokerState::new(BrokerConfig::new(8, 16, 8).unwrap())
  let publisher = @session.ClientId::new("sid-publisher").unwrap()
  let subscriber = @session.ClientId::new("sid-subscriber").unwrap()
  ignore(state.apply(CreateSession(publisher)))
  ignore(state.apply(CreateSession(subscriber)))
  let entries : Array[SubscribeEntryV5] = [
    {
      filter: @topic.TopicFilter::new("sid/#").unwrap(),
      qos: @session.QoS1,
      no_local: false,
      retain_as_published: false,
      retain_handling: 2,
      subscription_identifier: Some(7),
    },
    {
      filter: @topic.TopicFilter::new("sid/+").unwrap(),
      qos: @session.QoS1,
      no_local: false,
      retain_as_published: false,
      retain_handling: 2,
      subscription_identifier: Some(7),
    },
  ]
  ignore(state.apply(SubscribeV5({ client_id: subscriber, entries })).unwrap())
  let actions = state
    .apply(
      Publish({
        origin: Client(publisher),
        topic: @topic.TopicName::new("sid/a").unwrap(),
        payload: b"x",
        qos: @session.QoS1,
        retain: false,
      }),
    )
    .unwrap()
  assert_true(
    actions[0] is DeliverWithMetadata({ subscription_identifiers: [7, 7], .. }),
  )
}

///|
test "C-T09 offline SID survives queued delivery and attach replay" {
  let state = BrokerState::new(BrokerConfig::new(8, 16, 8).unwrap())
  let subscriber = @session.ClientId::new("sid-offline").unwrap()
  let publisher = @session.ClientId::new("sid-source").unwrap()
  ignore(
    state
    .apply(
      CreateSessionWith({
        client_id: subscriber,
        mode: @session.Persistent,
        attached: true,
      }),
    )
    .unwrap(),
  )
  ignore(state.apply(CreateSession(publisher)).unwrap())
  ignore(
    state
    .apply(
      SubscribeV5({
        client_id: subscriber,
        entries: [
          {
            filter: @topic.TopicFilter::new("offline/#").unwrap(),
            qos: @session.QoS1,
            no_local: false,
            retain_as_published: false,
            retain_handling: 2,
            subscription_identifier: Some(7),
          },
        ],
      }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(DetachSessionAt({ client_id: subscriber, detached_at_ms: 1L }))
    .unwrap(),
  )
  ignore(
    state
    .apply(
      Publish({
        origin: Client(publisher),
        topic: @topic.TopicName::new("offline/a").unwrap(),
        payload: b"queued",
        qos: @session.QoS1,
        retain: false,
      }),
    )
    .unwrap(),
  )
  let replay = state.apply(AttachSession(subscriber)).unwrap()
  assert_true(
    replay.any(action => {
      action is DeliverWithMetadata({ subscription_identifiers: [7], .. })
    }),
  )
}
