///|
fn invariant_state_client(value : String) -> @session.ClientId {
  @session.ClientId::new(value).unwrap()
}

///|
fn invariant_state_filter(value : String) -> @topic.TopicFilter {
  @topic.TopicFilter::new(value).unwrap()
}

///|
fn invariant_state_topic(value : String) -> @topic.TopicName {
  @topic.TopicName::new(value).unwrap()
}

///|
test "broker state rejects orphan and per-session subscription corruption" {
  let orphan = BrokerState::new(BrokerConfig::new(2, 2, 1).unwrap())
  ignore(
    orphan.subscriptions.put(
      invariant_state_client("missing"),
      invariant_state_filter("a"),
      @session.DeliveryQoS::QoS0,
    ),
  )
  assert_eq(
    orphan.check_invariants(),
    Err(
      RouterError::InvariantViolation("subscription references missing session"),
    ),
  )

  let per_session = BrokerState::new(BrokerConfig::new(0, 2, 1).unwrap())
  let client = invariant_state_client("client")
  per_session.sessions.set(client, @session.ClientSession::new(client))
  ignore(
    per_session.subscriptions.put(
      client,
      invariant_state_filter("a"),
      @session.DeliveryQoS::QoS0,
    ),
  )
  assert_eq(
    per_session.check_invariants(),
    Err(
      RouterError::InvariantViolation("per-session subscription limit exceeded"),
    ),
  )
}

///|
test "broker state rejects total and retained capacity corruption" {
  let total = BrokerState::new(BrokerConfig::new(2, 0, 1).unwrap())
  let client = invariant_state_client("client")
  total.sessions.set(client, @session.ClientSession::new(client))
  ignore(
    total.subscriptions.put(
      client,
      invariant_state_filter("a"),
      @session.DeliveryQoS::QoS0,
    ),
  )
  assert_eq(
    total.check_invariants(),
    Err(RouterError::InvariantViolation("total subscription limit exceeded")),
  )

  let retained = BrokerState::new(BrokerConfig::new(1, 1, 0).unwrap())
  ignore(
    retained.retained.put(
      invariant_state_topic("a"),
      b"x",
      @session.DeliveryQoS::QoS0,
      1,
    ),
  )
  assert_eq(
    retained.check_invariants(),
    Err(RouterError::InvariantViolation("retained message limit exceeded")),
  )
}

///|
test "broker state accepts sessions without subscriptions" {
  let state = BrokerState::new(BrokerConfig::new(1, 1, 1).unwrap())
  let client = invariant_state_client("idle")
  state.sessions.set(client, @session.ClientSession::new(client))
  assert_eq(state.check_invariants(), Ok(()))
}
