///|
fn security_fixture(
  allow_anonymous? : Bool = false,
) -> @security.SecurityPolicy raise {
  // Reference checked by scripts/check-argon2.sh (password: correct horse).
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  let passwords = match
    @security.PasswordDatabase::parse(
      "sensor01:" + encoded + "\nsensor02:" + encoded + "\n",
    ) {
    Ok(database) => database
    Err(@security.PasswordFileError::Argon2Unavailable) =>
      fail(
        "Argon2id tests require libargon2.so.1: install libargon2-1 on Ubuntu/Debian or use scripts/moon-docker.sh test --target native",
      )
    Err(_) =>
      fail(
        "invalid Argon2id test fixture: run scripts/check-argon2.sh to check the reference hash",
      )
  }
  let acl = @security.AclPolicy::parse(
    (
      #|user sensor01
      #|topic read allowed/#
      #|topic write allowed/#
      #|user sensor02
      #|topic read allowed/#
      #|topic write allowed/#
      #|anonymous
      #|topic read public/#
      #|
    ),
  ).unwrap()
  @security.SecurityPolicy::new(allow_anonymous~, passwords~, acl~)
}

///|
fn secure_runtime(allow_anonymous? : Bool = false) -> BrokerRuntime raise {
  let config = runtime_config()
  BrokerRuntime::new(
    config,
    @router.BrokerState::new(config.broker_config()),
    security=security_fixture(allow_anonymous~),
  )
}

///|
fn secure_async_runtime() -> BrokerRuntime raise {
  let config = runtime_config()
  BrokerRuntime::new(
    config,
    @router.BrokerState::new(config.broker_config()),
    security=security_fixture(),
    async_auth=true,
  )
}

///|
fn authentication_budget(rt : BrokerRuntime) -> Int64 {
  let mut total = 0L
  for entry in rt.broker_state().resource_ledger().usage() {
    let (kind, committed, reserved, _) = entry
    if kind == @budget.ResourceKind::AuthRequest ||
      kind == @budget.ResourceKind::AuthWorkspace {
      total += committed + reserved
    }
  }
  total
}

///|
fn authenticated_connect(
  client_id : String,
  password : Bytes,
  username? : String = "sensor01",
  clean_session? : Bool = true,
  will? : @protocol.WillMessage? = None,
) -> @protocol.Packet {
  Connect({
    client_id,
    username: Some(username),
    password: Some(password),
    keep_alive: 10,
    clean_session,
    will,
  })
}

///|
test "persistent Client ID is owned by Principal across takeover and resume" {
  let rt = secure_runtime()
  let alice = cid(806L)
  open(rt, alice, 0L)
  assert_eq(
    receive(
      rt,
      alice,
      authenticated_connect(
        "owned-session",
        b"correct horse",
        clean_session=false,
      ),
      1L,
    ),
    [SendPacket({ connection_id: alice, packet: test_connack(Accepted) })],
  )
  let bob = cid(807L)
  open(rt, bob, 0L)
  assert_eq(
    receive(
      rt,
      bob,
      authenticated_connect(
        "owned-session",
        b"correct horse",
        username="sensor02",
        clean_session=false,
      ),
      2L,
    ),
    [
      SendPacketThenClose({
        connection_id: bob,
        packet: test_connack(NotAuthorized),
        reason: ConnectRejected,
      }),
    ],
  )
  assert_eq(receive(rt, alice, Pingreq, 3L), [
    SendPacket({ connection_id: alice, packet: Pingresp }),
  ])
  ignore(receive(rt, alice, Disconnect, 4L))

  let bob_after = cid(808L)
  open(rt, bob_after, 5L)
  assert_true(
    receive(
      rt,
      bob_after,
      authenticated_connect(
        "owned-session",
        b"correct horse",
        username="sensor02",
        clean_session=false,
      ),
      6L,
    )[0]
    is SendPacketThenClose(_),
  )
  let alice_resume = cid(809L)
  open(rt, alice_resume, 7L)
  assert_eq(
    receive(
      rt,
      alice_resume,
      authenticated_connect(
        "owned-session",
        b"correct horse",
        clean_session=false,
      ),
      8L,
    )[0],
    SendPacket({
      connection_id: alice_resume,
      packet: Connack({ session_present: true, return_code: Accepted }),
    }),
  )
}

///|
test "runtime distinguishes missing and bad credentials before Session mutation" {
  let missing = secure_runtime()
  let missing_id = cid(801L)
  open(missing, missing_id, 0L)
  assert_eq(receive(missing, missing_id, connect_packet("missing"), 1L), [
    SendPacketThenClose({
      connection_id: missing_id,
      packet: test_connack(NotAuthorized),
      reason: ConnectRejected,
    }),
  ])
  assert_eq(missing.broker_state().session_count(), 0)

  let bad = secure_runtime()
  let bad_id = cid(802L)
  open(bad, bad_id, 0L)
  assert_eq(receive(bad, bad_id, authenticated_connect("bad", b"wrong"), 1L), [
    SendPacketThenClose({
      connection_id: bad_id,
      packet: test_connack(BadUsernameOrPassword),
      reason: ConnectRejected,
    }),
  ])
  assert_eq(bad.broker_state().session_count(), 0)
}

///|
test "runtime accepts Argon2id credentials and rejects unauthorized Will" {
  let accepted = secure_runtime()
  let accepted_id = cid(803L)
  open(accepted, accepted_id, 0L)
  assert_eq(
    receive(
      accepted,
      accepted_id,
      authenticated_connect("accepted", b"correct horse"),
      1L,
    ),
    [SendPacket({ connection_id: accepted_id, packet: test_connack(Accepted) })],
  )

  let denied = secure_runtime()
  let denied_id = cid(804L)
  open(denied, denied_id, 0L)
  let will : @protocol.WillMessage = {
    topic: "denied/will",
    payload: b"secret",
    qos: QoS1,
    retain: true,
  }
  assert_eq(
    receive(
      denied,
      denied_id,
      authenticated_connect("will-denied", b"correct horse", will=Some(will)),
      1L,
    ),
    [
      SendPacketThenClose({
        connection_id: denied_id,
        packet: test_connack(NotAuthorized),
        reason: ConnectRejected,
      }),
    ],
  )
  assert_eq(denied.broker_state().session_count(), 0)
}

///|
test "runtime returns partial SUBACK and acknowledges denied QoS1 without routing" {
  let rt = secure_runtime()
  let id = cid(805L)
  open(rt, id, 0L)
  ignore(
    receive(rt, id, authenticated_connect("acl-client", b"correct horse"), 1L),
  )
  let subscribe_id = @protocol.PacketId::new(41).unwrap()
  assert_eq(
    receive(
      rt,
      id,
      Subscribe({
        packet_id: subscribe_id,
        subscriptions: [
          { topic_filter: "allowed/+", requested_qos: QoS1 },
          { topic_filter: "denied/#", requested_qos: QoS1 },
          { topic_filter: "#", requested_qos: QoS0 },
        ],
      }),
      2L,
    ),
    [
      SendPacket({
        connection_id: id,
        packet: Suback({
          packet_id: subscribe_id,
          return_codes: [GrantedQoS1, Failure, Failure],
        }),
      }),
    ],
  )
  assert_eq(rt.broker_state().subscription_count(), 1)

  assert_eq(
    receive(
      rt,
      id,
      Publish({
        topic: "denied/value",
        payload: b"must-not-route",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: true,
      }),
      3L,
    ),
    [],
  )
  assert_eq(rt.broker_state().retained_count(), 0)
  let publish_id = @protocol.PacketId::new(42).unwrap()
  assert_eq(
    receive(
      rt,
      id,
      Publish({
        topic: "denied/value",
        payload: b"must-not-route",
        qos: QoS1,
        packet_id: Some(publish_id),
        dup: false,
        retain: true,
      }),
      4L,
    ),
    [SendPacket({ connection_id: id, packet: Puback(publish_id) })],
  )
  assert_eq(rt.broker_state().retained_count(), 0)
}

///|
test "async authentication commits only after a matching completion" {
  let rt = secure_async_runtime()
  let id = cid(820L)
  open(rt, id, 0L)
  let baseline = rt.broker_state().resource_ledger().committed()
  assert_eq(
    receive(rt, id, authenticated_connect("deferred", b"correct horse"), 1L),
    [StartAuthentication({ request_id: 1L })],
  )
  assert_eq(rt.auth_task_count(), 1)
  assert_eq(rt.broker_state().session_count(), 0)
  assert_true(rt.broker_state().resource_ledger().committed() > baseline)
  assert_true(rt.connections.get(id) is Some({ phase: Authenticating(1L), .. }))
  assert_eq(
    rt.apply(
      AuthenticationCompleted({
        request_id: 1L,
        outcome: @security.AuthCompletionOutcome::HashMatched,
        completed_at_ms: 2L,
      }),
    ),
    [SendPacket({ connection_id: id, packet: test_connack(Accepted) })],
  )
  assert_eq(rt.auth_task_count(), 0)
  assert_eq(authentication_budget(rt), 0L)
  assert_true(rt.connections.get(id) is Some({ phase: Active(_), .. }))
  assert_eq(
    rt.apply(
      AuthenticationCompleted({
        request_id: 1L,
        outcome: @security.AuthCompletionOutcome::HashMatched,
        completed_at_ms: 3L,
      }),
    ),
    [],
  )
  rt.check_invariants().unwrap()
}

///|
test "async authentication failure and submit failure never create sessions" {
  let mismatch = secure_async_runtime()
  let mismatch_id = cid(821L)
  open(mismatch, mismatch_id, 0L)
  ignore(
    receive(
      mismatch,
      mismatch_id,
      authenticated_connect("mismatch", b"wrong"),
      1L,
    ),
  )
  assert_true(
    mismatch.apply(
      AuthenticationCompleted({
        request_id: 1L,
        outcome: @security.AuthCompletionOutcome::HashMismatched,
        completed_at_ms: 2L,
      }),
    )[0]
    is SendPacketThenClose(_),
  )
  assert_eq(mismatch.broker_state().session_count(), 0)

  let failed = secure_async_runtime()
  let failed_id = cid(822L)
  open(failed, failed_id, 0L)
  ignore(
    receive(
      failed,
      failed_id,
      authenticated_connect("submit-failed", b"correct horse"),
      1L,
    ),
  )
  assert_true(
    failed.apply(AuthenticationSubmitFailed(1L))[0] is SendPacketThenClose(_),
  )
  assert_eq(failed.auth_task_count(), 0)
  assert_eq(failed.broker_state().session_count(), 0)
}

///|
test "async authentication disconnect keeps budget until native completion" {
  let rt = secure_async_runtime()
  let id = cid(823L)
  open(rt, id, 0L)
  let baseline = rt.broker_state().resource_ledger().committed()
  ignore(receive(rt, id, authenticated_connect("cancel", b"correct horse"), 1L))
  let reserved = rt.broker_state().resource_ledger().committed()
  assert_true(reserved > baseline)
  assert_eq(
    rt.apply(
      TransportClosed({ connection_id: id, reason: PeerEof, observed_at_ms: 2L }),
    ),
    [
      CancelAuthentication({ request_id: 1L }),
      CloseTransport({ connection_id: id, reason: PeerEof }),
    ],
  )
  assert_eq(rt.auth_task_count(), 1)
  assert_eq(rt.broker_state().resource_ledger().committed(), reserved)
  assert_eq(
    rt.apply(
      AuthenticationCompleted({
        request_id: 1L,
        outcome: @security.AuthCompletionOutcome::AuthFinishedAfterCancel,
        completed_at_ms: 3L,
      }),
    ),
    [],
  )
  assert_eq(rt.auth_task_count(), 0)
  assert_eq(rt.broker_state().resource_ledger().committed(), baseline)
  assert_eq(rt.broker_state().session_count(), 0)
}

///|
test "async authentication timeout cancels without activating or publishing Will" {
  let rt = secure_async_runtime()
  let id = cid(824L)
  open(rt, id, 0L)
  let will : @protocol.WillMessage = {
    topic: "allowed/will",
    payload: b"must-not-publish",
    qos: QoS1,
    retain: true,
  }
  ignore(
    receive(
      rt,
      id,
      authenticated_connect("timeout", b"correct horse", will=Some(will)),
      1L,
    ),
  )
  assert_eq(rt.apply(CheckDeadlines(999L)), [])
  assert_eq(rt.apply(CheckDeadlines(1000L)), [
    CancelAuthentication({ request_id: 1L }),
    CloseTransport({ connection_id: id, reason: ConnectTimeout }),
  ])
  assert_eq(rt.broker_state().session_count(), 0)
  assert_eq(rt.broker_state().retained_count(), 0)
  rt.check_invariants().unwrap()
  ignore(
    rt.apply(
      AuthenticationCompleted({
        request_id: 1L,
        outcome: @security.AuthCompletionOutcome::AuthFinishedAfterCancel,
        completed_at_ms: 1001L,
      }),
    ),
  )
  assert_eq(rt.auth_task_count(), 0)
  assert_eq(authentication_budget(rt), 0L)
}
