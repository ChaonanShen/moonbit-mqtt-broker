///|
async fn read_mqtt_packet(connection : @socket.Tcp) -> @protocol.Packet {
  let bytes : Array[Byte] = []
  bytes.push(connection.read_exactly(1)[0])
  let mut multiplier = 1
  let mut remaining = 0
  for index in 0..<4 {
    let digit = connection.read_exactly(1)[0]
    bytes.push(digit)
    remaining = remaining + (digit.to_int() & 127) * multiplier
    if (digit.to_int() & 128) == 0 {
      break
    }
    if index == 3 {
      fail("malformed remaining length from broker")
    }
    multiplier = multiplier * 128
  }
  if remaining > 0 {
    for byte in connection.read_exactly(remaining) {
      bytes.push(byte)
    }
  }
  @protocol.decode_packet(Bytes::from_array(bytes)).unwrap()
}

///|
fn network_connect_packet(
  client_id : String,
  clean_session? : Bool = true,
  keep_alive? : Int = 30,
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
async fn connect_network_client(
  addr : @socket.Addr,
  packet : @protocol.Packet,
) -> @socket.Tcp {
  let client = @socket.Tcp::connect(addr)
  client.write(@protocol.encode_packet(packet).unwrap())
  client
}

///|
async fn write_packet(
  connection : @socket.Tcp,
  packet : @protocol.Packet,
) -> Unit {
  connection.write(@protocol.encode_packet(packet).unwrap())
}

///|
async test "network qos0 subscribe publish and unsubscribe acknowledgements" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let subscriber = connect_network_client(
      listener.addr,
      network_connect_packet("net-subscriber"),
    )
    let publisher = connect_network_client(
      listener.addr,
      network_connect_packet("net-publisher"),
    )
    defer subscriber.close()
    defer publisher.close()
    assert_eq(
      read_mqtt_packet(subscriber),
      Connack({ session_present: false, return_code: Accepted }),
    )
    assert_eq(
      read_mqtt_packet(publisher),
      Connack({ session_present: false, return_code: Accepted }),
    )
    let subscribe_id = @protocol.PacketId::new(17).unwrap()
    write_packet(
      subscriber,
      Subscribe({
        packet_id: subscribe_id,
        subscriptions: [{ topic_filter: "network/+", requested_qos: QoS1 }],
      }),
    )
    assert_eq(
      read_mqtt_packet(subscriber),
      Suback({ packet_id: subscribe_id, return_codes: [GrantedQoS1] }),
    )
    write_packet(
      publisher,
      Publish({
        topic: "network/value",
        payload: b"hello",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: false,
      }),
    )
    assert_eq(
      read_mqtt_packet(subscriber),
      Publish({
        topic: "network/value",
        payload: b"hello",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: false,
      }),
    )
    let unsubscribe_id = @protocol.PacketId::new(18).unwrap()
    write_packet(
      subscriber,
      Unsubscribe({ packet_id: unsubscribe_id, topic_filters: ["network/+"] }),
    )
    assert_eq(read_mqtt_packet(subscriber), Unsuback(unsubscribe_id))
    write_packet(subscriber, Disconnect)
    write_packet(publisher, Disconnect)
    server.cancel()
  }
}

///|
async test "network retained publish is live without retain and replayed with retain" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let live = connect_network_client(
      listener.addr,
      network_connect_packet("live"),
    )
    let publisher = connect_network_client(
      listener.addr,
      network_connect_packet("retained-publisher"),
    )
    defer live.close()
    defer publisher.close()
    ignore(read_mqtt_packet(live))
    ignore(read_mqtt_packet(publisher))
    write_packet(
      live,
      Subscribe({
        packet_id: @protocol.PacketId::new(1).unwrap(),
        subscriptions: [{ topic_filter: "retained/#", requested_qos: QoS0 }],
      }),
    )
    ignore(read_mqtt_packet(live))
    write_packet(
      publisher,
      Publish({
        topic: "retained/value",
        payload: b"saved",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: true,
      }),
    )
    match read_mqtt_packet(live) {
      Publish(packet) => assert_false(packet.retain)
      _ => fail("expected live retained delivery")
    }
    let replay = connect_network_client(
      listener.addr,
      network_connect_packet("replay"),
    )
    defer replay.close()
    ignore(read_mqtt_packet(replay))
    write_packet(
      replay,
      Subscribe({
        packet_id: @protocol.PacketId::new(2).unwrap(),
        subscriptions: [{ topic_filter: "retained/#", requested_qos: QoS0 }],
      }),
    )
    assert_true(read_mqtt_packet(replay) is Suback(_))
    match read_mqtt_packet(replay) {
      Publish(packet) => {
        assert_true(packet.retain)
        assert_eq(packet.payload, b"saved")
      }
      _ => fail("expected retained replay")
    }
    write_packet(live, Disconnect)
    write_packet(publisher, Disconnect)
    write_packet(replay, Disconnect)
    server.cancel()
  }
}

///|
async test "network eof will fires while normal disconnect will is suppressed" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let subscriber = connect_network_client(
      listener.addr,
      network_connect_packet("will-subscriber"),
    )
    defer subscriber.close()
    ignore(read_mqtt_packet(subscriber))
    write_packet(
      subscriber,
      Subscribe({
        packet_id: @protocol.PacketId::new(1).unwrap(),
        subscriptions: [{ topic_filter: "will/#", requested_qos: QoS0 }],
      }),
    )
    ignore(read_mqtt_packet(subscriber))
    let normal_will : @protocol.WillMessage = {
      topic: "will/normal",
      payload: b"must-not-arrive",
      qos: QoS0,
      retain: false,
    }
    let normal = connect_network_client(
      listener.addr,
      network_connect_packet("normal-will", will=Some(normal_will)),
    )
    ignore(read_mqtt_packet(normal))
    write_packet(normal, Disconnect)
    assert_eq(normal.read_some(), None)
    normal.close()

    let eof_will : @protocol.WillMessage = {
      topic: "will/eof",
      payload: b"arrives",
      qos: QoS0,
      retain: false,
    }
    let abnormal = connect_network_client(
      listener.addr,
      network_connect_packet("eof-will", will=Some(eof_will)),
    )
    ignore(read_mqtt_packet(abnormal))
    abnormal.close()
    assert_eq(
      read_mqtt_packet(subscriber),
      Publish({
        topic: "will/eof",
        payload: b"arrives",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: false,
      }),
    )
    write_packet(subscriber, Disconnect)
    server.cancel()
  }
}

///|
async test "network client takeover closes old generation and keeps new active" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let subscriber = connect_network_client(
      listener.addr,
      network_connect_packet("takeover-observer"),
    )
    defer subscriber.close()
    ignore(read_mqtt_packet(subscriber))
    write_packet(
      subscriber,
      Subscribe({
        packet_id: @protocol.PacketId::new(1).unwrap(),
        subscriptions: [{ topic_filter: "takeover/#", requested_qos: QoS0 }],
      }),
    )
    ignore(read_mqtt_packet(subscriber))
    let old_will : @protocol.WillMessage = {
      topic: "takeover/will",
      payload: b"old",
      qos: QoS0,
      retain: false,
    }
    let old = connect_network_client(
      listener.addr,
      network_connect_packet("same-client", will=Some(old_will)),
    )
    ignore(read_mqtt_packet(old))
    let replacement = connect_network_client(
      listener.addr,
      network_connect_packet("same-client"),
    )
    defer replacement.close()
    assert_eq(
      read_mqtt_packet(subscriber),
      Publish({
        topic: "takeover/will",
        payload: b"old",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: false,
      }),
    )
    assert_eq(old.read_some(), None)
    assert_true(read_mqtt_packet(replacement) is Connack(_))
    write_packet(replacement, Pingreq)
    assert_eq(read_mqtt_packet(replacement), Pingresp)
    write_packet(replacement, Disconnect)
    write_packet(subscriber, Disconnect)
    old.close()
    server.cancel()
  }
}

///|
async test "network unsupported persistent session and qos1 will reject after connack" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let persistent = connect_network_client(
      listener.addr,
      network_connect_packet("persistent", clean_session=false),
    )
    assert_eq(
      read_mqtt_packet(persistent),
      Connack({ session_present: false, return_code: ServerUnavailable }),
    )
    assert_eq(persistent.read_some(), None)
    persistent.close()
    let qos1_will : @protocol.WillMessage = {
      topic: "will/qos1",
      payload: b"unsupported",
      qos: QoS1,
      retain: false,
    }
    let will_client = connect_network_client(
      listener.addr,
      network_connect_packet("qos1-will", will=Some(qos1_will)),
    )
    assert_eq(
      read_mqtt_packet(will_client),
      Connack({ session_present: false, return_code: ServerUnavailable }),
    )
    assert_eq(will_client.read_some(), None)
    will_client.close()
    server.cancel()
  }
}

///|
async test "initial broker state is injected before accept" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let state = loopback_state(config)
    ignore(
      state.apply(
        @router.BrokerEvent::Publish({
          origin: @router.PublishOrigin::Internal,
          topic: @topic.TopicName::new("injected/retained").unwrap(),
          payload: b"before-start",
          qos: @session.DeliveryQoS::QoS0,
          retain: true,
        }),
      ),
    )
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, state)
    }
    let client = connect_network_client(
      listener.addr,
      network_connect_packet("injected-subscriber"),
    )
    defer client.close()
    ignore(read_mqtt_packet(client))
    write_packet(
      client,
      Subscribe({
        packet_id: @protocol.PacketId::new(1).unwrap(),
        subscriptions: [{ topic_filter: "injected/#", requested_qos: QoS0 }],
      }),
    )
    assert_true(read_mqtt_packet(client) is Suback(_))
    assert_eq(
      read_mqtt_packet(client),
      Publish({
        topic: "injected/retained",
        payload: b"before-start",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: true,
      }),
    )
    write_packet(client, Disconnect)
    server.cancel()
  }
}

///|
async test "network inbound qos1 publish closes without puback" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let client = connect_network_client(
      listener.addr,
      network_connect_packet("qos1-publisher"),
    )
    ignore(read_mqtt_packet(client))
    write_packet(
      client,
      Publish({
        topic: "unsupported/qos1",
        payload: b"must-not-route",
        qos: QoS1,
        packet_id: Some(@protocol.PacketId::new(9).unwrap()),
        dup: false,
        retain: true,
      }),
    )
    assert_eq(client.read_some(), None)
    client.close()
    server.cancel()
  }
}

///|
async test "protocol error publishes qos0 will" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let observer = connect_network_client(
      listener.addr,
      network_connect_packet("protocol-observer"),
    )
    defer observer.close()
    ignore(read_mqtt_packet(observer))
    write_packet(
      observer,
      Subscribe({
        packet_id: @protocol.PacketId::new(1).unwrap(),
        subscriptions: [{ topic_filter: "protocol/will", requested_qos: QoS0 }],
      }),
    )
    ignore(read_mqtt_packet(observer))
    let will : @protocol.WillMessage = {
      topic: "protocol/will",
      payload: b"direction-error",
      qos: QoS0,
      retain: false,
    }
    let doomed = connect_network_client(
      listener.addr,
      network_connect_packet("protocol-doomed", will=Some(will)),
    )
    ignore(read_mqtt_packet(doomed))
    // PINGRESP is a server-to-client packet and is invalid from this peer.
    write_packet(doomed, Pingresp)
    assert_eq(doomed.read_some(), None)
    doomed.close()
    assert_eq(
      read_mqtt_packet(observer),
      Publish({
        topic: "protocol/will",
        payload: b"direction-error",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: false,
      }),
    )
    // PINGRESP is an ordering sentinel: a duplicate Will would be read first.
    write_packet(observer, Pingreq)
    assert_eq(read_mqtt_packet(observer), Pingresp)
    write_packet(observer, Disconnect)
    server.cancel()
  }
}

///|
async test "retained empty payload deletes stored message over tcp" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let live = connect_network_client(
      listener.addr,
      network_connect_packet("delete-live"),
    )
    let publisher = connect_network_client(
      listener.addr,
      network_connect_packet("delete-publisher"),
    )
    defer live.close()
    defer publisher.close()
    ignore(read_mqtt_packet(live))
    ignore(read_mqtt_packet(publisher))
    write_packet(
      live,
      Subscribe({
        packet_id: @protocol.PacketId::new(1).unwrap(),
        subscriptions: [
          { topic_filter: "retained/delete", requested_qos: QoS0 },
        ],
      }),
    )
    ignore(read_mqtt_packet(live))
    write_packet(
      publisher,
      Publish({
        topic: "retained/delete",
        payload: b"value",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: true,
      }),
    )
    assert_true(read_mqtt_packet(live) is Publish({ payload: b"value", .. }))
    write_packet(
      publisher,
      Publish({
        topic: "retained/delete",
        payload: b"",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: true,
      }),
    )
    // Receiving the live empty Publish proves the delete was applied before
    // the replay client is allowed to subscribe.
    assert_true(read_mqtt_packet(live) is Publish({ payload: b"", .. }))

    let replay = connect_network_client(
      listener.addr,
      network_connect_packet("delete-replay"),
    )
    defer replay.close()
    ignore(read_mqtt_packet(replay))
    write_packet(
      replay,
      Subscribe({
        packet_id: @protocol.PacketId::new(2).unwrap(),
        subscriptions: [
          { topic_filter: "retained/delete", requested_qos: QoS0 },
        ],
      }),
    )
    assert_true(read_mqtt_packet(replay) is Suback(_))
    write_packet(replay, Pingreq)
    assert_eq(read_mqtt_packet(replay), Pingresp)
    write_packet(live, Disconnect)
    write_packet(publisher, Disconnect)
    write_packet(replay, Disconnect)
    server.cancel()
  }
}
