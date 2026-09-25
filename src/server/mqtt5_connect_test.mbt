///|
fn v5_connect_test_packet() -> @protocol.ConnectV5 {
  {
    client_id: "device-a",
    username: None,
    password: None,
    keep_alive: 60,
    clean_start: false,
    properties: [],
    will: None,
  }
}

///|
test "C-T05 MQTT5 CONNECT negotiation and capability CONNACK" {
  let config = ServerConfig::default()
  let packet : @protocol.ConnectV5 = {
    ..v5_connect_test_packet(),
    properties: [
      { id: 0x11, value: @protocol.FourByteValue(30U) },
      { id: 0x21, value: @protocol.TwoByteValue(2) },
      { id: 0x22, value: @protocol.TwoByteValue(4) },
      { id: 0x27, value: @protocol.FourByteValue(100U) },
      { id: 0x17, value: @protocol.ByteValue(0) },
    ],
  }
  let plan = normalize_mqtt5_connect(packet, config, _ => false).unwrap()
  assert_eq(plan.retention, @session.FiniteV5(30U))
  assert_eq(plan.resume_decision, @session.ResumeExisting)
  assert_eq(plan.peer_receive_maximum, 2)
  assert_eq(plan.peer_topic_alias_maximum, 4)
  assert_eq(plan.peer_max_packet_bytes, 100)
  assert_false(plan.request_problem_information)
  let response = mqtt5_connack(plan, config, false)
  let encoded = @protocol.encode_v5(response, @protocol.ServerToClient, 100).unwrap()
  assert_true(encoded.length() > 5)
  assert_true(response is @protocol.Connack5({ properties: [..], .. }))
  assert_true(
    @protocol.encode_v5(response, @protocol.ServerToClient, 5) is Err(_),
  )
}

///|
test "C-T05 MQTT5 unsupported auth method and malformed Will payload" {
  let config = ServerConfig::default()
  let auth : @protocol.ConnectV5 = {
    ..v5_connect_test_packet(),
    properties: [{ id: 0x15, value: @protocol.StringValue("method") }],
  }
  assert_eq(
    normalize_mqtt5_connect(auth, config, _ => false),
    Err({ reason: 0x8c }),
  )
  let bad_will : @protocol.ConnectV5 = {
    ..v5_connect_test_packet(),
    will: Some({
      topic: "status/a",
      payload: b"\xff",
      qos: @protocol.QoS0,
      retain: false,
      properties: [{ id: 0x01, value: @protocol.ByteValue(1) }],
    }),
  }
  assert_eq(
    normalize_mqtt5_connect(bad_will, config, _ => false),
    Err({ reason: 0x99 }),
  )
}

///|
test "M-T26 MQTT5 CONNACK does not claim optional response namespace" {
  let config = ServerConfig::default()
  let packet : @protocol.ConnectV5 = {
    ..v5_connect_test_packet(),
    properties: [{ id: 0x19, value: @protocol.ByteValue(1) }],
  }
  let plan = normalize_mqtt5_connect(packet, config, _ => false).unwrap()
  let properties = match mqtt5_connack(plan, config, false) {
    @protocol.Connack5(value) => value.properties
    _ => fail("expected CONNACK")
  }
  for id in [0x21, 0x22, 0x25, 0x27, 0x28, 0x29, 0x2a] {
    assert_true(properties.any(item => item.id == id))
  }
  assert_true(
    properties.any(item => {
      item.id == 0x2a && item.value == @protocol.ByteValue(0)
    }),
  )
  for id in [0x1a, 0x1c, 0x24] {
    assert_false(properties.any(item => item.id == id))
  }
}
