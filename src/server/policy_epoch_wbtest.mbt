///|
fn policy_epoch_runtime() -> BrokerRuntime {
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  let passwords = @security.PasswordDatabase::parse("sensor01:" + encoded).unwrap()
  let security = @security.SecurityPolicy::new(
    allow_anonymous=false,
    passwords~,
  )
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  BrokerRuntime::new(
    config,
    @router.BrokerState::new(broker_config),
    security~,
    async_auth=true,
  )
}

///|
fn policy_epoch_connect() -> @protocol.Packet {
  Connect({
    client_id: "stale-auth",
    username: Some("sensor01"),
    password: Some(b"correct horse"),
    keep_alive: 10,
    clean_session: true,
    will: None,
  })
}

///|
test "stale policy epoch rejects ordinary authentication completion" {
  let rt = policy_epoch_runtime()
  let id = ConnectionId::new(850L)
  ignore(rt.apply(TransportOpened({ connection_id: id, accepted_at_ms: 0L })))
  assert_eq(
    rt.apply(
      PacketReceived({
        connection_id: id,
        packet: policy_epoch_connect(),
        received_at_ms: 1L,
      }),
    ),
    [StartAuthentication({ request_id: 1L })],
  )
  assert_true(
    rt.publish_security_generation(@security.SecurityPolicy::permissive(), 1L),
  )
  let actions = rt.apply(
    AuthenticationCompleted({
      request_id: 1L,
      outcome: @security.AuthCompletionOutcome::HashMatched,
      completed_at_ms: 2L,
    }),
  )
  assert_true(actions[0] is SendPacketThenClose(_))
  assert_eq(rt.broker_state().session_count(), 0)
  assert_eq(rt.auth_task_count(), 0)
  rt.check_invariants().unwrap()
}

///|
test "stale policy epoch rejects strict authentication completion" {
  let rt = policy_epoch_runtime()
  let id = ConnectionId::new(851L)
  ignore(rt.apply(TransportOpened({ connection_id: id, accepted_at_ms: 0L })))
  let decision = rt.prepare_strict_connect_packet(
    { connection_id: id, packet: policy_epoch_connect(), received_at_ms: 1L },
    Map([]),
    1L,
  )
  assert_true(decision is StrictImmediate(_))
  assert_true(
    rt.publish_security_generation(@security.SecurityPolicy::permissive(), 1L),
  )
  let result = rt.prepare_strict_auth_completion(
    {
      request_id: 1L,
      outcome: @security.AuthCompletionOutcome::HashMatched,
      completed_at_ms: 2L,
    },
    Map([]),
    1L,
  )
  match result {
    StrictImmediate(actions) =>
      assert_true(actions[0] is SendPacketThenClose(_))
    _ => fail("stale strict authentication must be rejected immediately")
  }
  assert_eq(rt.broker_state().session_count(), 0)
  assert_eq(rt.auth_task_count(), 0)
  rt.check_invariants().unwrap()
}

///|
test "strict active packet closes a revoked credential before preparing WAL" {
  let rt = policy_epoch_runtime()
  let id = ConnectionId::new(853L)
  ignore(rt.apply(TransportOpened({ connection_id: id, accepted_at_ms: 0L })))
  let connect : @protocol.Packet = match policy_epoch_connect() {
    Connect(value) =>
      Connect({
        ..value,
        will: Some({
          topic: "allowed/will",
          payload: b"must-not-publish",
          qos: QoS1,
          retain: true,
        }),
      })
    _ => abort("invalid connect fixture")
  }
  let begin = rt.prepare_strict_connect_packet(
    { connection_id: id, packet: connect, received_at_ms: 1L },
    Map([]),
    1L,
  )
  assert_true(begin is StrictImmediate(_))
  let completed = rt.prepare_strict_auth_completion(
    {
      request_id: 1L,
      outcome: @security.AuthCompletionOutcome::HashMatched,
      completed_at_ms: 2L,
    },
    Map([]),
    1L,
  )
  let (plan, after) = match completed {
    StrictPrepared(plan, after) => (plan, after)
    _ => fail("strict authentication must prepare activation")
  }
  rt.broker_state().begin_action_scope()
  ignore(after(plan.commit().unwrap()))
  rt.broker_state().end_action_scope()
  assert_true(
    rt.publish_security_generation(@security.SecurityPolicy::permissive(), 1L),
  )
  let result = rt.prepare_strict_active_packet(
    {
      connection_id: id,
      packet: Publish({
        topic: "allowed/value",
        payload: b"must-not-route",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: true,
      }),
      received_at_ms: 3L,
    },
    Map([]),
  )
  assert_true(result is StrictClose(_, PolicyRevoked))
  let closed = rt.finish_strict_transport_close({
    connection_id: id,
    reason: PolicyRevoked,
    observed_at_ms: 4L,
  })
  assert_false(closed.any(action => action is StartDurableWill(_)))
  assert_eq(rt.broker_state().retained_count(), 0)
}
