///|
fn v5_limits() -> DecodeLimits {
  {
    max_packet_bytes: 1048576,
    max_property_bytes: 4096,
    max_user_properties: 64,
    max_subscription_entries: 256,
  }
}

///|
test "C-T03 MQTT5 independent CONNECT and CONNACK vectors" {
  let connect = PacketV5::Connect5({
    client_id: "a",
    username: None,
    password: None,
    keep_alive: 0,
    clean_start: true,
    properties: [],
    will: None,
  })
  let expected = b"\x10\x0e\x00\x04MQTT\x05\x02\x00\x00\x00\x00\x01a"
  assert_eq(encode_v5(connect, ClientToServer, 100), Ok(expected))
  assert_eq(decode_v5(expected, ClientToServer, v5_limits()), Ok(connect))
  let connack = PacketV5::Connack5({
    session_present: false,
    reason: 0,
    properties: [],
  })
  assert_eq(
    encode_v5(connack, ServerToClient, 100),
    Ok(b"\x20\x03\x00\x00\x00"),
  )
  assert_eq(
    decode_v5(b"\x20\x03\x00\x00\x00", ServerToClient, v5_limits()),
    Ok(connack),
  )
}

///|
test "C-T03 MQTT5 shortest ACK and disconnect" {
  let id = PacketId::new(7).unwrap()
  let ack = PacketV5::Puback5({ packet_id: id, reason: 0, properties: [] })
  assert_eq(encode_v5(ack, ServerToClient, 100), Ok(b"\x40\x02\x00\x07"))
  assert_eq(
    decode_v5(b"\x40\x02\x00\x07", ServerToClient, v5_limits()),
    Ok(ack),
  )
  let disconnect = PacketV5::Disconnect5({ reason: 0, properties: [] })
  assert_eq(encode_v5(disconnect, ServerToClient, 100), Ok(b"\xe0\x00"))
  assert_eq(
    decode_v5(b"\xe0\x02\x00\x00", ServerToClient, v5_limits()),
    Ok(disconnect),
  )
  assert_true(
    decode_v5(b"\x6a\x02\x00\x07", ClientToServer, v5_limits()) is Err(_),
  )
}

///|
test "C-T03 MQTT5 SUBSCRIBE options and identifier vector" {
  let id = PacketId::new(7).unwrap()
  let subscribe = PacketV5::Subscribe5({
    packet_id: id,
    properties: [{ id: 0x0b, value: PropertyValue::VariableValue(9) }],
    subscriptions: [
      {
        topic_filter: "a/+",
        requested_qos: QoS::QoS1,
        no_local: true,
        retain_as_published: true,
        retain_handling: 2,
      },
    ],
  })
  let vector = b"\x82\x0b\x00\x07\x02\x0b\x09\x00\x03a/+\x2d"
  assert_eq(encode_v5(subscribe, ClientToServer, 100), Ok(vector))
  assert_eq(decode_v5(vector, ClientToServer, v5_limits()), Ok(subscribe))
  assert_true(
    decode_v5(
      b"\x82\x0b\x00\x07\x02\x0b\x09\x00\x03a/+\xfd",
      ClientToServer,
      v5_limits(),
    )
    is Err(_),
  )
}

///|
test "C-T03 MQTT5 metadata PUBLISH matches independent mqtt-packet bytes" {
  let vector = b"\x32\x42\x00\x08sensor/a\x00\x2a\x33\x01\x01\x02\x00\x00\x00\x0a\x03\x00\x0atext/plain\x08\x00\x07reply/a\x09\x00\x02\x00\xff\x26\x00\x01k\x00\x02v1\x26\x00\x01k\x00\x02v2ok"
  let packet = PacketV5::Publish5({
    topic: "sensor/a",
    payload: b"ok",
    qos: QoS::QoS1,
    packet_id: Some(PacketId::new(42).unwrap()),
    dup: false,
    retain: false,
    properties: [
      { id: 0x01, value: PropertyValue::ByteValue(1) },
      { id: 0x02, value: PropertyValue::FourByteValue(10U) },
      { id: 0x03, value: PropertyValue::StringValue("text/plain") },
      { id: 0x08, value: PropertyValue::StringValue("reply/a") },
      { id: 0x09, value: PropertyValue::BinaryValue(b"\x00\xff") },
      { id: 0x26, value: PropertyValue::StringPair("k", "v1") },
      { id: 0x26, value: PropertyValue::StringPair("k", "v2") },
    ],
  })
  assert_eq(decode_v5(vector, ClientToServer, v5_limits()), Ok(packet))
  assert_eq(encode_v5(packet, ClientToServer, 100), Ok(vector))
}
