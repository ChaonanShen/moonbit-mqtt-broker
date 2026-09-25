///|
test "C-T04 MQTT5 first pass measures property and subscription shape" {
  let limits : DecodeLimits = {
    max_packet_bytes: 1048576,
    max_property_bytes: 16384,
    max_user_properties: 64,
    max_subscription_entries: 256,
  }
  let connect = b"\x10\x0e\x00\x04MQTT\x05\x02\x00\x00\x00\x00\x01a"
  let first = scan_v5_frame_shape(connect, ClientToServer, limits).unwrap()
  assert_eq(first.string_count, 2)
  assert_eq(first.string_bytes, 5)
  assert_eq(first.property_count, 0)
  let subscribe = b"\x82\x0b\x00\x07\x02\x0b\x09\x00\x03a/+\x2d"
  let second = scan_v5_frame_shape(subscribe, ClientToServer, limits).unwrap()
  assert_eq(second.property_count, 1)
  assert_eq(second.entry_count, 1)
  assert_eq(second.string_bytes, 3)
  assert_true(
    scan_v5_frame_shape(subscribe, ClientToServer, {
      ..limits,
      max_subscription_entries: 0,
    })
    is Err(WireLimitExceeded(_)),
  )
}

///|
test "C-T04 large MQTT5 payload is charged linearly before decoding" {
  let payload = Bytes::make(900000, b'x')
  let packet : PacketV5 = Publish5({
    topic: "large/payload",
    payload,
    qos: QoS0,
    packet_id: None,
    dup: false,
    retain: false,
    properties: [],
  })
  let frame = encode_v5(packet, ClientToServer, 1000000).unwrap()
  let limits : DecodeLimits = {
    max_packet_bytes: 1000000,
    max_property_bytes: 16384,
    max_user_properties: 64,
    max_subscription_entries: 256,
  }
  let shape = scan_v5_frame_shape(frame, ClientToServer, limits).unwrap()
  assert_eq(shape.payload_bytes, 900000)
  assert_true(shape.logical_cost() >= 900000L)
  assert_true(shape.logical_cost() < 1000000L)
  assert_true(
    scan_v5_frame_shape(frame, ClientToServer, {
      ..limits,
      max_packet_bytes: 1000,
    })
    is Err(WireLimitExceeded(_)),
  )
}
