///|
test "wire codec chooses MQTT protocol version on first CONNECT" {
  let limits : DecodeLimits = {
    max_packet_bytes: 100,
    max_property_bytes: 100,
    max_user_properties: 8,
    max_subscription_entries: 8,
  }
  let v5 = b"\x10\x0e\x00\x04MQTT\x05\x02\x00\x00\x00\x00\x01a"
  assert_true(
    decode_wire(v5, FirstConnect, ClientToServer, limits)
    is Ok(WirePacket::V5(_)),
  )
  let v311 = b"\x10\x0d\x00\x04MQTT\x04\x02\x00\x00\x00\x01a"
  assert_true(
    decode_wire(v311, FirstConnect, ClientToServer, limits)
    is Ok(WirePacket::V311(_)),
  )
  assert_true(
    decode_wire(v5, Established(ProtocolVersion::V311), ClientToServer, limits)
    is Err(_),
  )
  assert_true(
    decode_wire(v311, Established(ProtocolVersion::V5), ClientToServer, limits)
    is Err(_),
  )
}
