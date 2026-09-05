///|
async test "network qos2 publish uses puback and subscriber packet id" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let subscriber = connect_network_client(
      listener.addr,
      network_connect_packet("qos2-live-subscriber"),
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
        subscriptions: [{ topic_filter: "qos2/live", requested_qos: QoS2 }],
      }),
    )
    assert_eq(
      read_mqtt_packet(subscriber),
      Suback({ packet_id: subscribe_id, return_codes: [GrantedQoS2] }),
    )
    let publisher = connect_network_client(
      listener.addr,
      network_connect_packet("qos2-live-publisher"),
    )
    defer publisher.close()
    ignore(read_mqtt_packet(publisher))
    let incoming_id = @protocol.PacketId::new(77).unwrap()
    write_packet(
      publisher,
      Publish({
        topic: "qos2/live",
        payload: b"wire-qos2",
        qos: QoS2,
        packet_id: Some(incoming_id),
        dup: false,
        retain: false,
      }),
    )
    assert_eq(read_mqtt_packet(publisher), Pubrec(incoming_id))
    let outgoing_id = match read_mqtt_packet(subscriber) {
      Publish(packet) => {
        assert_eq(packet.topic, "qos2/live")
        assert_eq(packet.payload, b"wire-qos2")
        assert_eq(packet.qos, QoS2)
        assert_false(packet.dup)
        packet.packet_id.unwrap()
      }
      _ => fail("subscriber must receive qos2 PUBLISH")
    }
    write_packet(publisher, Pubrel(incoming_id))
    assert_eq(read_mqtt_packet(publisher), Pubcomp(incoming_id))
    write_packet(subscriber, Pubrec(outgoing_id))
    assert_eq(read_mqtt_packet(subscriber), Pubrel(outgoing_id))
    write_packet(subscriber, Pubrec(outgoing_id))
    assert_eq(read_mqtt_packet(subscriber), Pubrel(outgoing_id))
    write_packet(subscriber, Pubcomp(outgoing_id))
    write_packet(publisher, Disconnect)
    write_packet(subscriber, Disconnect)
    server.cancel()
  }
}
