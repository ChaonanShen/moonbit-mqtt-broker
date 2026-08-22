///|
fn runtime_config(
  max_connections? : Int = 8,
  max_retained? : Int = 8,
) -> ServerConfig {
  let broker = @router.BrokerConfig::new(8, 32, max_retained).unwrap()
  ServerConfig::new(max_connections, 1024, 2048, 8, 32, 1000, 100, broker).unwrap()
}

///|
fn runtime(config? : ServerConfig = runtime_config()) -> BrokerRuntime {
  BrokerRuntime::new(config, @router.BrokerState::new(config.broker_config()))
}

///|
fn cid(value : Int64) -> ConnectionId {
  ConnectionId::new(value)
}

///|
fn test_connack(code : @protocol.ConnectReturnCode) -> @protocol.Packet {
  Connack({ session_present: false, return_code: code })
}

///|
fn connect_packet(
  client_id : String,
  clean_session? : Bool = true,
  keep_alive? : Int = 10,
  will? : @protocol.WillMessage? = None,
) -> @protocol.Packet {
  Connect({
    client_id,
    username: None,
    password: None,
    keep_alive,
    clean_session,
    will,
  })
}

///|
fn open(rt : BrokerRuntime, id : ConnectionId, now : Int64) -> Unit raise {
  assert_eq(
    rt.apply(TransportOpened({ connection_id: id, accepted_at_ms: now })),
    [],
  )
}

///|
fn receive(
  rt : BrokerRuntime,
  id : ConnectionId,
  packet : @protocol.Packet,
  now : Int64,
) -> Array[RuntimeAction] {
  rt.apply(PacketReceived({ connection_id: id, packet, received_at_ms: now }))
}

///|
fn connect(
  rt : BrokerRuntime,
  id : ConnectionId,
  client : String,
) -> Unit raise {
  open(rt, id, 0L)
  assert_eq(receive(rt, id, connect_packet(client), 1L), [
    SendPacket({ connection_id: id, packet: test_connack(Accepted) }),
  ])
}

///|
test "runtime accepts clean connect and ping without tcp" {
  let rt = runtime()
  let id = cid(1L)
  connect(rt, id, "client")
  assert_eq(receive(rt, id, Pingreq, 100L), [
    SendPacket({ connection_id: id, packet: Pingresp }),
  ])
  assert_eq(rt.connection_count(), 1)
  assert_eq(rt.broker_state().session_count(), 1)
  assert_eq(rt.check_invariants(), Ok(()))
}

///|
test "runtime enforces first packet and duplicate connect" {
  let first = runtime()
  let first_id = cid(1L)
  open(first, first_id, 0L)
  assert_eq(receive(first, first_id, Pingreq, 1L), [
    CloseTransport({ connection_id: first_id, reason: ProtocolError }),
  ])
  assert_false(first.has_connection(first_id))

  let duplicate = runtime()
  let duplicate_id = cid(2L)
  connect(duplicate, duplicate_id, "duplicate")
  assert_eq(receive(duplicate, duplicate_id, connect_packet("duplicate"), 2L), [
    CloseTransport({ connection_id: duplicate_id, reason: ProtocolError }),
  ])
  assert_eq(duplicate.broker_state().session_count(), 0)
}

///|
test "runtime returns specified connack for unsupported sessions" {
  let empty = runtime()
  let empty_id = cid(1L)
  open(empty, empty_id, 0L)
  assert_eq(
    receive(empty, empty_id, connect_packet("", clean_session=false), 1L),
    [
      SendPacketThenClose({
        connection_id: empty_id,
        packet: test_connack(IdentifierRejected),
        reason: ConnectRejected,
      }),
    ],
  )

  let persistent = runtime()
  let persistent_id = cid(2L)
  open(persistent, persistent_id, 0L)
  assert_eq(
    receive(
      persistent,
      persistent_id,
      connect_packet("persistent", clean_session=false),
      1L,
    ),
    [
      SendPacketThenClose({
        connection_id: persistent_id,
        packet: test_connack(ServerUnavailable),
        reason: ConnectRejected,
      }),
    ],
  )
  assert_eq(persistent.broker_state().session_count(), 0)
}

///|
test "runtime assigns unique internal ids to empty clean clients" {
  let rt = runtime()
  for value in 1L..<3L {
    let id = cid(value)
    open(rt, id, 0L)
    assert_eq(receive(rt, id, connect_packet(""), 1L).length(), 1)
  }
  assert_eq(rt.broker_state().session_count(), 2)
  assert_eq(rt.check_invariants(), Ok(()))
}

///|
test "runtime rejects qos1 will before creating session" {
  let rt = runtime()
  let id = cid(1L)
  open(rt, id, 0L)
  let will : @protocol.WillMessage = {
    topic: "will/topic",
    payload: b"bye",
    qos: QoS1,
    retain: false,
  }
  assert_eq(receive(rt, id, connect_packet("client", will=Some(will)), 1L), [
    SendPacketThenClose({
      connection_id: id,
      packet: test_connack(ServerUnavailable),
      reason: ConnectRejected,
    }),
  ])
  assert_eq(rt.broker_state().session_count(), 0)
}

///|
test "runtime routes qos0 and correlates subscription packet id" {
  let rt = runtime()
  let subscriber = cid(1L)
  let publisher = cid(2L)
  connect(rt, subscriber, "subscriber")
  connect(rt, publisher, "publisher")
  let packet_id = @protocol.PacketId::new(41).unwrap()
  assert_eq(
    receive(
      rt,
      subscriber,
      Subscribe({
        packet_id,
        subscriptions: [{ topic_filter: "sensors/+", requested_qos: QoS1 }],
      }),
      2L,
    ),
    [
      SendPacket({
        connection_id: subscriber,
        packet: Suback({ packet_id, return_codes: [GrantedQoS1] }),
      }),
    ],
  )
  assert_eq(
    receive(
      rt,
      publisher,
      Publish({
        topic: "sensors/a",
        payload: b"22",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: false,
      }),
      3L,
    ),
    [
      SendPacket({
        connection_id: subscriber,
        packet: Publish({
          topic: "sensors/a",
          payload: b"22",
          qos: QoS0,
          packet_id: None,
          dup: false,
          retain: false,
        }),
      }),
    ],
  )
}

///|
test "runtime sends suback before retained replay and supports unsubscribe" {
  let rt = runtime()
  let publisher = cid(1L)
  let subscriber = cid(2L)
  connect(rt, publisher, "publisher")
  ignore(
    receive(
      rt,
      publisher,
      Publish({
        topic: "retained/a",
        payload: b"saved",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: true,
      }),
      2L,
    ),
  )
  connect(rt, subscriber, "subscriber")
  let subscribe_id = @protocol.PacketId::new(7).unwrap()
  let actions = receive(
    rt,
    subscriber,
    Subscribe({
      packet_id: subscribe_id,
      subscriptions: [{ topic_filter: "retained/#", requested_qos: QoS0 }],
    }),
    3L,
  )
  assert_eq(actions.length(), 2)
  assert_eq(
    actions[0],
    SendPacket({
      connection_id: subscriber,
      packet: Suback({ packet_id: subscribe_id, return_codes: [GrantedQoS0] }),
    }),
  )
  match actions[1] {
    SendPacket({ packet: Publish(packet), .. }) => assert_true(packet.retain)
    _ => fail("expected retained publish")
  }
  let unsubscribe_id = @protocol.PacketId::new(8).unwrap()
  assert_eq(
    receive(
      rt,
      subscriber,
      Unsubscribe({ packet_id: unsubscribe_id, topic_filters: ["retained/#"] }),
      4L,
    ),
    [
      SendPacket({ connection_id: subscriber, packet: Unsuback(unsubscribe_id) }),
    ],
  )
  assert_eq(rt.broker_state().subscription_count(), 0)
}

///|
test "qos1 publish closes before routing or retaining" {
  let rt = runtime()
  let id = cid(1L)
  connect(rt, id, "publisher")
  assert_eq(
    receive(
      rt,
      id,
      Publish({
        topic: "unsupported",
        payload: b"value",
        qos: QoS1,
        packet_id: Some(@protocol.PacketId::new(1).unwrap()),
        dup: false,
        retain: true,
      }),
      2L,
    ),
    [CloseTransport({ connection_id: id, reason: ProtocolError })],
  )
  assert_eq(rt.broker_state().retained_count(), 0)
}

///|
test "will publishes on eof but normal disconnect suppresses it" {
  let rt = runtime()
  let subscriber = cid(1L)
  connect(rt, subscriber, "subscriber")
  ignore(
    receive(
      rt,
      subscriber,
      Subscribe({
        packet_id: @protocol.PacketId::new(1).unwrap(),
        subscriptions: [{ topic_filter: "will/#", requested_qos: QoS0 }],
      }),
      2L,
    ),
  )
  let abnormal = cid(2L)
  let will : @protocol.WillMessage = {
    topic: "will/abnormal",
    payload: b"bye",
    qos: QoS0,
    retain: false,
  }
  open(rt, abnormal, 0L)
  ignore(receive(rt, abnormal, connect_packet("abnormal", will=Some(will)), 1L))
  let closed = rt.apply(
    TransportClosed({
      connection_id: abnormal,
      reason: PeerEof,
      observed_at_ms: 3L,
    }),
  )
  assert_eq(closed.length(), 2)
  match closed[0] {
    SendPacket({ connection_id, packet: Publish(packet) }) => {
      assert_eq(connection_id, subscriber)
      assert_eq(packet.payload, b"bye")
    }
    _ => fail("expected will delivery")
  }
  assert_eq(
    closed[1],
    CloseTransport({ connection_id: abnormal, reason: PeerEof }),
  )

  let normal = cid(3L)
  open(rt, normal, 0L)
  ignore(receive(rt, normal, connect_packet("normal", will=Some(will)), 1L))
  assert_eq(receive(rt, normal, Disconnect, 4L), [
    CloseTransport({ connection_id: normal, reason: NormalDisconnect }),
  ])
}

///|
test "takeover publishes old will once and stale close cannot remove new session" {
  let rt = runtime()
  let old_id = cid(1L)
  let new_id = cid(2L)
  let will : @protocol.WillMessage = {
    topic: "takeover/will",
    payload: b"old",
    qos: QoS0,
    retain: true,
  }
  open(rt, old_id, 0L)
  ignore(receive(rt, old_id, connect_packet("same", will=Some(will)), 1L))
  open(rt, new_id, 2L)
  let takeover = receive(rt, new_id, connect_packet("same"), 3L)
  assert_eq(
    takeover[0],
    CloseTransport({ connection_id: old_id, reason: ClientTakeover }),
  )
  assert_eq(
    takeover[1],
    SendPacket({ connection_id: new_id, packet: test_connack(Accepted) }),
  )
  assert_eq(rt.broker_state().retained_count(), 1)
  assert_eq(
    rt.apply(
      TransportClosed({
        connection_id: old_id,
        reason: PeerEof,
        observed_at_ms: 4L,
      }),
    ),
    [],
  )
  assert_true(rt.has_connection(new_id))
  assert_eq(rt.broker_state().session_count(), 1)
  assert_eq(rt.broker_state().retained_count(), 1)
}

///|
test "deadlines use exact connect and keepalive boundaries" {
  let connect_rt = runtime()
  let awaiting = cid(1L)
  open(connect_rt, awaiting, 100L)
  assert_eq(connect_rt.apply(CheckDeadlines(1099L)), [])
  assert_eq(connect_rt.apply(CheckDeadlines(1100L)), [
    CloseTransport({ connection_id: awaiting, reason: ConnectTimeout }),
  ])

  let active_rt = runtime()
  let active = cid(2L)
  open(active_rt, active, 0L)
  ignore(
    receive(active_rt, active, connect_packet("active", keep_alive=1), 10L),
  )
  assert_eq(active_rt.apply(CheckDeadlines(1509L)), [])
  assert_eq(active_rt.apply(CheckDeadlines(1510L)), [
    CloseTransport({ connection_id: active, reason: KeepAliveTimeout }),
  ])

  let disabled_rt = runtime()
  let disabled = cid(3L)
  open(disabled_rt, disabled, 0L)
  ignore(
    receive(disabled_rt, disabled, connect_packet("disabled", keep_alive=0), 1L),
  )
  assert_eq(disabled_rt.apply(CheckDeadlines(999999L)), [])
}

///|
test "connection limit rejects new transport without changing runtime" {
  let rt = runtime(config=runtime_config(max_connections=1))
  let first = cid(1L)
  let second = cid(2L)
  open(rt, first, 0L)
  assert_eq(
    rt.apply(TransportOpened({ connection_id: second, accepted_at_ms: 0L })),
    [CloseTransport({ connection_id: second, reason: ServerShutdown })],
  )
  assert_eq(rt.connection_count(), 1)
}
