///|
fn security_fixture(
  allow_anonymous? : Bool = false,
) -> @security.SecurityPolicy {
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  let passwords = @security.PasswordDatabase::parse(
    "sensor01:" + encoded + "\nsensor02:" + encoded + "\n",
  ).unwrap()
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
fn secure_runtime(allow_anonymous? : Bool = false) -> BrokerRuntime {
  let config = runtime_config()
  BrokerRuntime::new(
    config,
    @router.BrokerState::new(config.broker_config()),
    security=security_fixture(allow_anonymous~),
  )
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
