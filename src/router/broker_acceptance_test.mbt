///|
fn accept_client(value : String) -> @session.ClientId {
  @session.ClientId::new(value).unwrap()
}

///|
fn accept_filter(value : String) -> @topic.TopicFilter {
  @topic.TopicFilter::new(value).unwrap()
}

///|
fn accept_topic(value : String) -> @topic.TopicName {
  @topic.TopicName::new(value).unwrap()
}

///|
fn accept_publish(
  origin : PublishOrigin,
  topic : String,
  payload : Bytes,
  qos : @session.DeliveryQoS,
  retain : Bool,
) -> BrokerEvent {
  BrokerEvent::Publish({
    origin,
    topic: accept_topic(topic),
    payload,
    qos,
    retain,
  })
}

///|
test "subscribe applies per-session and total limits entry by entry" {
  let state = BrokerState::new(BrokerConfig::new(1, 2, 2).unwrap())
  let alice = accept_client("alice")
  let bob = accept_client("bob")
  ignore(state.apply(BrokerEvent::CreateSession(alice)))
  ignore(state.apply(BrokerEvent::CreateSession(bob)))
  assert_eq(
    state.apply(
      BrokerEvent::Subscribe({
        client_id: alice,
        entries: [
          { filter: accept_filter("a"), qos: @session.DeliveryQoS::QoS0 },
          { filter: accept_filter("b"), qos: @session.DeliveryQoS::QoS1 },
        ],
      }),
    ),
    Ok([
      BrokerAction::SubscriptionsApplied({
        client_id: alice,
        results: [
          SubscribeResult::Granted(@session.DeliveryQoS::QoS0),
          SubscribeResult::RejectedLimit(LimitKind::SubscriptionsPerSession),
        ],
      }),
    ]),
  )
  ignore(
    state.apply(
      BrokerEvent::Subscribe({
        client_id: bob,
        entries: [
          { filter: accept_filter("b"), qos: @session.DeliveryQoS::QoS0 },
        ],
      }),
    ),
  )
  assert_eq(
    state.apply(
      BrokerEvent::Subscribe({
        client_id: bob,
        entries: [
          { filter: accept_filter("c"), qos: @session.DeliveryQoS::QoS0 },
        ],
      }),
    ),
    Ok([
      BrokerAction::SubscriptionsApplied({
        client_id: bob,
        results: [
          SubscribeResult::RejectedLimit(LimitKind::SubscriptionsPerSession),
        ],
      }),
    ]),
  )
  assert_eq(state.subscription_count(), 2)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "subscription updates and duplicates succeed at capacity" {
  let state = BrokerState::new(BrokerConfig::new(1, 1, 1).unwrap())
  let client = accept_client("client")
  let filter = accept_filter("a")
  ignore(state.apply(BrokerEvent::CreateSession(client)))
  let result = state
    .apply(
      BrokerEvent::Subscribe({
        client_id: client,
        entries: [
          { filter, qos: @session.DeliveryQoS::QoS0 },
          { filter, qos: @session.DeliveryQoS::QoS1 },
        ],
      }),
    )
    .unwrap()
  assert_eq(result, [
    BrokerAction::SubscriptionsApplied({
      client_id: client,
      results: [
        SubscribeResult::Granted(@session.DeliveryQoS::QoS0),
        SubscribeResult::Granted(@session.DeliveryQoS::QoS1),
      ],
    }),
  ])
  assert_eq(state.subscription_count(), 1)
  assert_eq(
    state.subscription_qos(client, filter),
    Some(@session.DeliveryQoS::QoS1),
  )
}

///|
test "zero subscription limits reject without mutation" {
  let state = BrokerState::new(BrokerConfig::new(0, 0, 1).unwrap())
  let client = accept_client("client")
  ignore(state.apply(BrokerEvent::CreateSession(client)))
  assert_eq(
    state.apply(
      BrokerEvent::Subscribe({
        client_id: client,
        entries: [
          { filter: accept_filter("#"), qos: @session.DeliveryQoS::QoS0 },
        ],
      }),
    ),
    Ok([
      BrokerAction::SubscriptionsApplied({
        client_id: client,
        results: [
          SubscribeResult::RejectedLimit(LimitKind::SubscriptionsPerSession),
        ],
      }),
    ]),
  )
  assert_eq(state.subscription_count(), 0)
}

///|
test "global subscription limit rejects a different session" {
  let state = BrokerState::new(BrokerConfig::new(2, 1, 1).unwrap())
  let alice = accept_client("alice")
  let bob = accept_client("bob")
  for client in [alice, bob] {
    ignore(state.apply(BrokerEvent::CreateSession(client)))
  }
  ignore(
    state.apply(
      BrokerEvent::Subscribe({
        client_id: alice,
        entries: [
          { filter: accept_filter("a"), qos: @session.DeliveryQoS::QoS0 },
        ],
      }),
    ),
  )
  assert_eq(
    state.apply(
      BrokerEvent::Subscribe({
        client_id: bob,
        entries: [
          { filter: accept_filter("b"), qos: @session.DeliveryQoS::QoS1 },
        ],
      }),
    ),
    Ok([
      BrokerAction::SubscriptionsApplied({
        client_id: bob,
        results: [SubscribeResult::RejectedLimit(LimitKind::SubscriptionsTotal)],
      }),
    ]),
  )
  assert_eq(state.subscription_count(), 1)
}

///|
test "unsubscribe and remove session preserve retained messages" {
  let state = BrokerState::new(BrokerConfig::new(3, 3, 1).unwrap())
  let client = accept_client("client")
  ignore(state.apply(BrokerEvent::CreateSession(client)))
  ignore(
    state.apply(
      BrokerEvent::Subscribe({
        client_id: client,
        entries: [
          { filter: accept_filter("a"), qos: @session.DeliveryQoS::QoS0 },
          { filter: accept_filter("b"), qos: @session.DeliveryQoS::QoS0 },
        ],
      }),
    ),
  )
  ignore(
    state.apply(
      accept_publish(
        PublishOrigin::Internal,
        "retained",
        b"x",
        @session.DeliveryQoS::QoS0,
        true,
      ),
    ),
  )
  assert_eq(
    state.apply(
      BrokerEvent::Unsubscribe({
        client_id: client,
        filters: [accept_filter("a"), accept_filter("a")],
      }),
    ),
    Ok([
      BrokerAction::UnsubscriptionsApplied({
        client_id: client,
        removed: [true, false],
      }),
    ]),
  )
  assert_eq(
    state.apply(BrokerEvent::RemoveSession(client)),
    Ok([BrokerAction::SessionRemoved(client)]),
  )
  assert_eq(state.subscription_count(), 0)
  assert_eq(state.retained_count(), 1)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "publish qos is minimum of publish and maximum matching subscription" {
  let state = BrokerState::new(BrokerConfig::new(2, 4, 1).unwrap())
  let low = accept_client("low")
  let high = accept_client("high")
  for client in [low, high] {
    ignore(state.apply(BrokerEvent::CreateSession(client)))
  }
  ignore(
    state.apply(
      BrokerEvent::Subscribe({
        client_id: low,
        entries: [
          { filter: accept_filter("a/#"), qos: @session.DeliveryQoS::QoS0 },
        ],
      }),
    ),
  )
  ignore(
    state.apply(
      BrokerEvent::Subscribe({
        client_id: high,
        entries: [
          { filter: accept_filter("a/#"), qos: @session.DeliveryQoS::QoS0 },
          { filter: accept_filter("a/+"), qos: @session.DeliveryQoS::QoS1 },
        ],
      }),
    ),
  )
  let qos0 = state
    .apply(
      accept_publish(
        PublishOrigin::Internal,
        "a/b",
        b"0",
        @session.DeliveryQoS::QoS0,
        false,
      ),
    )
    .unwrap()
  assert_eq(qos0, [
    BrokerAction::Deliver({
      recipient: high,
      topic: accept_topic("a/b"),
      payload: b"0",
      qos: @session.DeliveryQoS::QoS0,
      retain: false,
      packet_id: None,
      dup: false,
    }),
    BrokerAction::Deliver({
      recipient: low,
      topic: accept_topic("a/b"),
      payload: b"0",
      qos: @session.DeliveryQoS::QoS0,
      retain: false,
      packet_id: None,
      dup: false,
    }),
  ])
  let qos1 = state
    .apply(
      accept_publish(
        PublishOrigin::Internal,
        "a/b",
        b"1",
        @session.DeliveryQoS::QoS1,
        true,
      ),
    )
    .unwrap()
  assert_eq(
    qos1[0],
    BrokerAction::Deliver({
      recipient: high,
      topic: accept_topic("a/b"),
      payload: b"1",
      qos: @session.DeliveryQoS::QoS1,
      retain: false,
      packet_id: Some(@session.SessionPacketId::new(1).unwrap()),
      dup: false,
    }),
  )
  assert_eq(
    qos1[1],
    BrokerAction::Deliver({
      recipient: low,
      topic: accept_topic("a/b"),
      payload: b"1",
      qos: @session.DeliveryQoS::QoS0,
      retain: false,
      packet_id: None,
      dup: false,
    }),
  )
}

///|
test "publish routing covers exact plus hash empty levels and system topics" {
  let state = BrokerState::new(BrokerConfig::new(1, 5, 1).unwrap())
  let filters = ["a//b", "a/+/b", "a/#", "#", "$SYS/#"]
  for index in 0..<filters.length() {
    let client = accept_client("client-\{index}")
    ignore(state.apply(BrokerEvent::CreateSession(client)))
    ignore(
      state.apply(
        BrokerEvent::Subscribe({
          client_id: client,
          entries: [
            {
              filter: accept_filter(filters[index]),
              qos: @session.DeliveryQoS::QoS0,
            },
          ],
        }),
      ),
    )
  }
  let empty_level = state
    .apply(
      accept_publish(
        PublishOrigin::Internal,
        "a//b",
        b"x",
        @session.DeliveryQoS::QoS0,
        false,
      ),
    )
    .unwrap()
  assert_eq(empty_level.length(), 4)
  let system = state
    .apply(
      accept_publish(
        PublishOrigin::Internal,
        "$SYS/health",
        b"x",
        @session.DeliveryQoS::QoS0,
        false,
      ),
    )
    .unwrap()
  assert_eq(system, [
    BrokerAction::Deliver({
      recipient: accept_client("client-4"),
      topic: accept_topic("$SYS/health"),
      payload: b"x",
      qos: @session.DeliveryQoS::QoS0,
      retain: false,
      packet_id: None,
      dup: false,
    }),
  ])
}

///|
test "publish origins share routing and retained semantics" {
  let publisher = accept_client("publisher")
  let origins = [
    PublishOrigin::Client(publisher),
    PublishOrigin::Will(publisher),
    PublishOrigin::Internal,
  ]
  let observed : Array[Array[BrokerAction]] = []
  for origin in origins {
    let state = BrokerState::new(BrokerConfig::new(1, 1, 1).unwrap())
    let target = accept_client("target")
    ignore(state.apply(BrokerEvent::CreateSession(target)))
    ignore(
      state.apply(
        BrokerEvent::Subscribe({
          client_id: target,
          entries: [
            { filter: accept_filter("a"), qos: @session.DeliveryQoS::QoS1 },
          ],
        }),
      ),
    )
    observed.push(
      state
      .apply(
        accept_publish(origin, "a", b"x", @session.DeliveryQoS::QoS1, true),
      )
      .unwrap(),
    )
    assert_eq(state.retained_message(accept_topic("a")).unwrap().payload, b"x")
  }
  assert_eq(observed[0], observed[1])
  assert_eq(observed[1], observed[2])
}

///|
test "retained replacement deletion replay and system wildcard rules" {
  let state = BrokerState::new(BrokerConfig::new(2, 4, 2).unwrap())
  ignore(
    state.apply(
      accept_publish(
        PublishOrigin::Internal,
        "a",
        b"old",
        @session.DeliveryQoS::QoS0,
        true,
      ),
    ),
  )
  ignore(
    state.apply(
      accept_publish(
        PublishOrigin::Internal,
        "a",
        b"new",
        @session.DeliveryQoS::QoS1,
        true,
      ),
    ),
  )
  ignore(
    state.apply(
      accept_publish(
        PublishOrigin::Internal,
        "$SYS/x",
        b"sys",
        @session.DeliveryQoS::QoS0,
        true,
      ),
    ),
  )
  let client = accept_client("client")
  ignore(state.apply(BrokerEvent::CreateSession(client)))
  let replay = state
    .apply(
      BrokerEvent::Subscribe({
        client_id: client,
        entries: [
          { filter: accept_filter("#"), qos: @session.DeliveryQoS::QoS0 },
          { filter: accept_filter("a"), qos: @session.DeliveryQoS::QoS1 },
        ],
      }),
    )
    .unwrap()
  assert_eq(replay.length(), 2)
  assert_eq(
    replay[1],
    BrokerAction::Deliver({
      recipient: client,
      topic: accept_topic("a"),
      payload: b"new",
      qos: @session.DeliveryQoS::QoS1,
      retain: true,
      packet_id: Some(@session.SessionPacketId::new(1).unwrap()),
      dup: false,
    }),
  )
  let deletion = state
    .apply(
      accept_publish(
        PublishOrigin::Internal,
        "a",
        b"",
        @session.DeliveryQoS::QoS1,
        true,
      ),
    )
    .unwrap()
  assert_eq(deletion.length(), 1)
  assert_eq(state.retained_message(accept_topic("a")), None)
}

///|
test "router errors are atomic" {
  let state = BrokerState::new(BrokerConfig::new(1, 1, 0).unwrap())
  let client = accept_client("client")
  let missing = accept_client("missing")
  ignore(state.apply(BrokerEvent::CreateSession(client)))
  ignore(
    state.apply(
      BrokerEvent::Subscribe({
        client_id: client,
        entries: [
          { filter: accept_filter("a"), qos: @session.DeliveryQoS::QoS0 },
        ],
      }),
    ),
  )
  let errors = [
    state.apply(BrokerEvent::CreateSession(client)),
    state.apply(BrokerEvent::RemoveSession(missing)),
    state.apply(
      BrokerEvent::Subscribe({
        client_id: missing,
        entries: [
          { filter: accept_filter("b"), qos: @session.DeliveryQoS::QoS0 },
        ],
      }),
    ),
    state.apply(BrokerEvent::Subscribe({ client_id: client, entries: [] })),
    state.apply(
      BrokerEvent::Unsubscribe({
        client_id: missing,
        filters: [accept_filter("a")],
      }),
    ),
    state.apply(BrokerEvent::Unsubscribe({ client_id: client, filters: [] })),
    state.apply(
      accept_publish(
        PublishOrigin::Internal,
        "retained",
        b"x",
        @session.DeliveryQoS::QoS0,
        true,
      ),
    ),
  ]
  for error in errors {
    assert_true(error is Err(_))
  }
  assert_eq(state.session_count(), 1)
  assert_eq(state.subscription_count(), 1)
  assert_eq(state.retained_count(), 0)
  assert_eq(
    state.subscription_qos(client, accept_filter("a")),
    Some(@session.DeliveryQoS::QoS0),
  )
  assert_eq(state.check_invariants(), Ok(()))
}
