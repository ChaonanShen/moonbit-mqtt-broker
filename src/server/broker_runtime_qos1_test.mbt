///|
fn persistent_connect(
  rt : BrokerRuntime,
  id : ConnectionId,
  client : String,
  session_present : Bool,
) -> Unit raise {
  open(rt, id, 0L)
  assert_eq(receive(rt, id, connect_packet(client, clean_session=false), 1L), [
    SendPacket({
      connection_id: id,
      packet: Connack({ session_present, return_code: Accepted }),
    }),
  ])
}

///|
fn subscribe_qos1(
  rt : BrokerRuntime,
  id : ConnectionId,
  filter : String,
  packet_id_value : Int,
) -> Unit raise {
  let packet_id = @protocol.PacketId::new(packet_id_value).unwrap()
  assert_eq(
    receive(
      rt,
      id,
      Subscribe({
        packet_id,
        subscriptions: [{ topic_filter: filter, requested_qos: QoS1 }],
      }),
      2L,
    ),
    [
      SendPacket({
        connection_id: id,
        packet: Suback({ packet_id, return_codes: [GrantedQoS1] }),
      }),
    ],
  )
}

///|
test "outbound qos1 remains inflight until puback at runtime" {
  let rt = runtime()
  let subscriber = cid(101L)
  let publisher = cid(102L)
  connect(rt, subscriber, "qos1-subscriber")
  subscribe_qos1(rt, subscriber, "qos1/live", 1)
  connect(rt, publisher, "qos1-publisher")
  let incoming = @protocol.PacketId::new(44).unwrap()
  let actions = receive(
    rt,
    publisher,
    Publish({
      topic: "qos1/live",
      payload: b"value",
      qos: QoS1,
      packet_id: Some(incoming),
      dup: false,
      retain: false,
    }),
    3L,
  )
  assert_eq(
    actions[0],
    SendPacket({ connection_id: publisher, packet: Puback(incoming) }),
  )
  let outgoing = match actions[1] {
    SendPacket({ connection_id, packet: Publish(packet) }) => {
      assert_eq(connection_id, subscriber)
      assert_eq(packet.qos, QoS1)
      assert_false(packet.dup)
      packet.packet_id.unwrap()
    }
    _ => fail("subscriber must receive qos1 publish")
  }
  assert_eq(rt.broker_state().inflight_count(), 1)
  assert_eq(
    receive(rt, subscriber, Puback(@protocol.PacketId::new(999).unwrap()), 4L),
    [],
  )
  assert_eq(rt.broker_state().inflight_count(), 1)
  assert_eq(receive(rt, subscriber, Puback(outgoing), 5L), [])
  assert_eq(rt.broker_state().inflight_count(), 0)
  assert_eq(rt.check_invariants(), Ok(()))
}

///|
test "persistent reconnect replays original packet id with dup after connack" {
  let rt = runtime()
  let first = cid(111L)
  persistent_connect(rt, first, "persistent", false)
  subscribe_qos1(rt, first, "offline/#", 1)
  assert_eq(
    rt.apply(
      TransportClosed({
        connection_id: first,
        reason: PeerEof,
        observed_at_ms: 3L,
      }),
    ),
    [CloseTransport({ connection_id: first, reason: PeerEof })],
  )
  let publisher = cid(112L)
  connect(rt, publisher, "publisher")
  let incoming = @protocol.PacketId::new(9).unwrap()
  assert_eq(
    receive(
      rt,
      publisher,
      Publish({
        topic: "offline/one",
        payload: b"queued",
        qos: QoS1,
        packet_id: Some(incoming),
        dup: false,
        retain: false,
      }),
      4L,
    ),
    [SendPacket({ connection_id: publisher, packet: Puback(incoming) })],
  )
  assert_eq(rt.broker_state().pending_qos1_count(), 1)

  let second = cid(113L)
  open(rt, second, 5L)
  let resumed = receive(
    rt,
    second,
    connect_packet("persistent", clean_session=false),
    6L,
  )
  assert_eq(
    resumed[0],
    SendPacket({
      connection_id: second,
      packet: Connack({ session_present: true, return_code: Accepted }),
    }),
  )
  let original_id = match resumed[1] {
    SendPacket({ packet: Publish(packet), .. }) => {
      assert_false(packet.dup)
      assert_eq(packet.payload, b"queued")
      packet.packet_id.unwrap()
    }
    _ => fail("pending qos1 must be promoted after CONNACK")
  }
  ignore(
    rt.apply(
      TransportClosed({
        connection_id: second,
        reason: PeerEof,
        observed_at_ms: 7L,
      }),
    ),
  )
  let third = cid(114L)
  open(rt, third, 8L)
  let replay = receive(
    rt,
    third,
    connect_packet("persistent", clean_session=false),
    9L,
  )
  assert_eq(
    replay[0],
    SendPacket({
      connection_id: third,
      packet: Connack({ session_present: true, return_code: Accepted }),
    }),
  )
  match replay[1] {
    SendPacket({ packet: Publish(packet), .. }) => {
      assert_eq(packet.packet_id, Some(original_id))
      assert_true(packet.dup)
      assert_eq(packet.payload, b"queued")
    }
    _ => fail("unacknowledged qos1 must replay after CONNACK")
  }
  assert_eq(receive(rt, third, Puback(original_id), 10L), [])
  assert_eq(rt.broker_state().inflight_count(), 0)
  assert_eq(rt.check_invariants(), Ok(()))
}

///|
test "clean session discards previous persistent state" {
  let rt = runtime()
  let first = cid(121L)
  persistent_connect(rt, first, "replace", false)
  subscribe_qos1(rt, first, "saved", 1)
  ignore(
    rt.apply(
      TransportClosed({
        connection_id: first,
        reason: PeerEof,
        observed_at_ms: 3L,
      }),
    ),
  )
  let clean = cid(122L)
  connect(rt, clean, "replace")
  let client_id = @session.ClientId::new("replace").unwrap()
  assert_eq(
    rt.broker_state().session_mode(client_id),
    Some(@session.SessionMode::Clean),
  )
  assert_eq(
    rt
    .broker_state()
    .subscription_qos(client_id, @topic.TopicFilter::new("saved").unwrap()),
    None,
  )
  assert_eq(rt.check_invariants(), Ok(()))
}

///|
test "qos1 will survives offline routing and reconnect" {
  let rt = runtime()
  let subscriber = cid(131L)
  persistent_connect(rt, subscriber, "will-subscriber", false)
  subscribe_qos1(rt, subscriber, "will/qos1", 1)
  ignore(
    rt.apply(
      TransportClosed({
        connection_id: subscriber,
        reason: NormalDisconnect,
        observed_at_ms: 3L,
      }),
    ),
  )
  let source = cid(132L)
  open(rt, source, 4L)
  let will : @protocol.WillMessage = {
    topic: "will/qos1",
    payload: b"offline",
    qos: QoS1,
    retain: true,
  }
  assert_eq(
    receive(rt, source, connect_packet("will-source", will=Some(will)), 5L),
    [SendPacket({ connection_id: source, packet: test_connack(Accepted) })],
  )
  ignore(
    rt.apply(
      TransportClosed({
        connection_id: source,
        reason: PeerEof,
        observed_at_ms: 6L,
      }),
    ),
  )
  assert_eq(rt.broker_state().pending_qos1_count(), 1)
  assert_eq(rt.broker_state().retained_count(), 1)
  let resumed = cid(133L)
  open(rt, resumed, 7L)
  let actions = receive(
    rt,
    resumed,
    connect_packet("will-subscriber", clean_session=false),
    8L,
  )
  match actions[1] {
    SendPacket({ packet: Publish(packet), .. }) => {
      assert_eq(packet.payload, b"offline")
      assert_eq(packet.qos, QoS1)
    }
    _ => fail("qos1 Will must be queued for persistent subscriber")
  }
}

///|
test "session limit maps connect failure to server unavailable" {
  let broker = @router.BrokerConfig::new(1, 1, 1, max_sessions=0).unwrap()
  let config = ServerConfig::new(2, 1024, 2048, 8, 16, 1000, 100, broker).unwrap()
  let rt = BrokerRuntime::new(config, @router.BrokerState::new(broker))
  let id = cid(141L)
  open(rt, id, 0L)
  assert_eq(receive(rt, id, connect_packet("limited"), 1L), [
    SendPacketThenClose({
      connection_id: id,
      packet: test_connack(ServerUnavailable),
      reason: ConnectRejected,
    }),
  ])
  assert_eq(rt.broker_state().session_count(), 0)
}

///|
test "twenty persistent clients detach and resume empty sessions" {
  let rt = runtime(config=runtime_config(max_connections=32))
  for index in 0..<20 {
    let id = cid(200L + index.to_int64())
    persistent_connect(rt, id, "persistent-\{index}", false)
    assert_eq(receive(rt, id, Disconnect, 2L), [
      CloseTransport({ connection_id: id, reason: NormalDisconnect }),
    ])
  }
  assert_eq(rt.broker_state().session_count(), 20)
  assert_eq(rt.connection_count(), 0)
  for index in 0..<20 {
    let id = cid(300L + index.to_int64())
    persistent_connect(rt, id, "persistent-\{index}", true)
  }
  assert_eq(rt.connection_count(), 20)
  assert_eq(rt.check_invariants(), Ok(()))
}
