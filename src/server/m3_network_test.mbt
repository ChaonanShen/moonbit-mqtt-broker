///|
async test "network qos1 publish uses puback and subscriber packet id" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let subscriber = connect_network_client(
      listener.addr,
      network_connect_packet("m3-live-subscriber"),
    )
    defer subscriber.close()
    assert_eq(
      read_mqtt_packet(subscriber),
      Connack({ session_present: false, return_code: Accepted }),
    )
    let subscribe_id = @protocol.PacketId::new(1).unwrap()
    write_packet(
      subscriber,
      Subscribe({
        packet_id: subscribe_id,
        subscriptions: [{ topic_filter: "m3/live", requested_qos: QoS1 }],
      }),
    )
    assert_eq(
      read_mqtt_packet(subscriber),
      Suback({ packet_id: subscribe_id, return_codes: [GrantedQoS1] }),
    )
    let publisher = connect_network_client(
      listener.addr,
      network_connect_packet("m3-live-publisher"),
    )
    defer publisher.close()
    ignore(read_mqtt_packet(publisher))
    let incoming_id = @protocol.PacketId::new(77).unwrap()
    write_packet(
      publisher,
      Publish({
        topic: "m3/live",
        payload: b"wire-qos1",
        qos: QoS1,
        packet_id: Some(incoming_id),
        dup: false,
        retain: false,
      }),
    )
    assert_eq(read_mqtt_packet(publisher), Puback(incoming_id))
    let outgoing_id = match read_mqtt_packet(subscriber) {
      Publish(packet) => {
        assert_eq(packet.topic, "m3/live")
        assert_eq(packet.payload, b"wire-qos1")
        assert_eq(packet.qos, QoS1)
        assert_false(packet.dup)
        packet.packet_id.unwrap()
      }
      _ => fail("subscriber must receive qos1 PUBLISH")
    }
    write_packet(subscriber, Puback(outgoing_id))
    write_packet(publisher, Disconnect)
    write_packet(subscriber, Disconnect)
    server.cancel()
  }
}

///|
async test "network persistent reconnect sets session present and replays dup" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let first = connect_network_client(
      listener.addr,
      network_connect_packet("m3-persistent", clean_session=false),
    )
    assert_eq(
      read_mqtt_packet(first),
      Connack({ session_present: false, return_code: Accepted }),
    )
    let subscribe_id = @protocol.PacketId::new(2).unwrap()
    write_packet(
      first,
      Subscribe({
        packet_id: subscribe_id,
        subscriptions: [{ topic_filter: "m3/offline", requested_qos: QoS1 }],
      }),
    )
    ignore(read_mqtt_packet(first))
    first.close()

    let publisher = connect_network_client(
      listener.addr,
      network_connect_packet("m3-offline-publisher"),
    )
    defer publisher.close()
    ignore(read_mqtt_packet(publisher))
    let incoming_id = @protocol.PacketId::new(88).unwrap()
    write_packet(
      publisher,
      Publish({
        topic: "m3/offline",
        payload: b"stored",
        qos: QoS1,
        packet_id: Some(incoming_id),
        dup: false,
        retain: false,
      }),
    )
    assert_eq(read_mqtt_packet(publisher), Puback(incoming_id))

    let second = connect_network_client(
      listener.addr,
      network_connect_packet("m3-persistent", clean_session=false),
    )
    assert_eq(
      read_mqtt_packet(second),
      Connack({ session_present: true, return_code: Accepted }),
    )
    let original_id = match read_mqtt_packet(second) {
      Publish(packet) => {
        assert_eq(packet.payload, b"stored")
        assert_false(packet.dup)
        packet.packet_id.unwrap()
      }
      _ => fail("offline qos1 must be delivered after CONNACK")
    }
    second.close()

    let third = connect_network_client(
      listener.addr,
      network_connect_packet("m3-persistent", clean_session=false),
    )
    defer third.close()
    assert_eq(
      read_mqtt_packet(third),
      Connack({ session_present: true, return_code: Accepted }),
    )
    match read_mqtt_packet(third) {
      Publish(packet) => {
        assert_eq(packet.packet_id, Some(original_id))
        assert_true(packet.dup)
        assert_eq(packet.payload, b"stored")
      }
      _ => fail("unacknowledged qos1 must replay with DUP")
    }
    write_packet(third, Puback(original_id))
    write_packet(third, Disconnect)
    write_packet(publisher, Disconnect)
    server.cancel()
  }
}
