///|
fn expiry_state(expiry_ms? : Int64 = 100L, limit? : Int = 2) -> BrokerState {
  let config = BrokerConfig::new(
    8,
    64,
    8,
    max_sessions=16,
    persistent_session_expiry_ms=expiry_ms,
    max_session_expirations_per_tick=limit,
  ).unwrap()
  BrokerState::new(config)
}

///|
fn expiry_client(value : String) -> @session.ClientId {
  @session.ClientId::new(value).unwrap()
}

///|
fn add_detached_session(
  state : BrokerState,
  name : String,
  detached_at_ms : Int64,
) -> @session.ClientId {
  let client_id = expiry_client(name)
  ignore(
    state.apply(
      CreateOwnedSessionWith({
        client_id,
        mode: @session.SessionMode::Persistent,
        attached: true,
        owner: @security.Principal::User(name),
      }),
    ),
  )
  ignore(state.apply(DetachSessionAt({ client_id, detached_at_ms })))
  client_id
}

///|
test "persistent Session expiry is exact deterministic and bounded per tick" {
  let state = expiry_state()
  let c = add_detached_session(state, "c", 100L)
  let a = add_detached_session(state, "a", 100L)
  let b = add_detached_session(state, "b", 100L)
  assert_eq(state.apply(ExpireSessions(199L)), Ok([]))
  let first = state.apply(ExpireSessions(200L)).unwrap()
  assert_true(first.contains(SessionExpired(a)))
  assert_true(first.contains(SessionExpired(b)))
  assert_false(first.contains(SessionExpired(c)))
  assert_eq(state.session_count(), 1)
  assert_true(state.has_session(c))
  assert_true(
    state.apply(ExpireSessions(200L)).unwrap().contains(SessionExpired(c)),
  )
  assert_eq(state.session_count(), 0)
}

///|
test "active Session does not expire and reconnect resets detach time" {
  let state = expiry_state()
  let active = expiry_client("active")
  ignore(
    state.apply(
      CreateOwnedSessionWith({
        client_id: active,
        mode: @session.SessionMode::Persistent,
        attached: true,
        owner: @security.Principal::User("active"),
      }),
    ),
  )
  assert_eq(state.apply(ExpireSessions(50L)), Ok([]))
  assert_true(state.has_session(active))

  let resumed = add_detached_session(state, "resumed", 100L)
  ignore(state.apply(AttachSession(resumed)))
  assert_eq(state.session_detached_at_ms(resumed), None)
  ignore(
    state.apply(DetachSessionAt({ client_id: resumed, detached_at_ms: 250L })),
  )
  assert_eq(state.apply(ExpireSessions(349L)), Ok([]))
  assert_true(
    state.apply(ExpireSessions(350L)).unwrap().contains(SessionExpired(resumed)),
  )
}

///|
test "unknown legacy detach time gets a full window and time regression delays" {
  let state = expiry_state()
  let legacy = add_detached_session(state, "legacy", 0L)
  assert_eq(state.apply(ExpireSessions(1000L)), Ok([]))
  assert_eq(state.session_detached_at_ms(legacy), Some(1000L))
  assert_eq(state.apply(ExpireSessions(1099L)), Ok([]))
  assert_true(
    state.apply(ExpireSessions(1100L)).unwrap().contains(SessionExpired(legacy)),
  )

  let rollback = expiry_state()
  ignore(rollback.apply(ExpireSessions(500L)))
  assert_eq(
    rollback.apply(ExpireSessions(400L)),
    Ok([TimeRegressionDetected(500L, 400L)]),
  )
  assert_eq(rollback.apply(ExpireSessions(400L)), Ok([]))
  assert_eq(rollback.apply(ExpireSessions(500L)), Ok([]))
}

///|
test "expiration removes subscriptions and queued QoS1 counters" {
  let state = expiry_state(limit=4)
  let client = expiry_client("resources")
  ignore(
    state.apply(
      CreateOwnedSessionWith({
        client_id: client,
        mode: @session.SessionMode::Persistent,
        attached: true,
        owner: @security.Principal::User("resources"),
      }),
    ),
  )
  ignore(
    state.apply(
      Subscribe({
        client_id: client,
        entries: [
          {
            filter: @topic.TopicFilter::new("expiry/#").unwrap(),
            qos: @session.DeliveryQoS::QoS1,
          },
        ],
      }),
    ),
  )
  ignore(
    state.apply(DetachSessionAt({ client_id: client, detached_at_ms: 10L })),
  )
  ignore(
    state.apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("expiry/value").unwrap(),
        payload: b"queued",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      }),
    ),
  )
  assert_eq(state.subscription_count(), 1)
  assert_eq(state.pending_qos1_count(), 1)
  ignore(state.apply(ExpireSessions(110L)))
  assert_eq(state.subscription_count(), 0)
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}
