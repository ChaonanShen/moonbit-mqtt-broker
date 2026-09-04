///|
test "qos2 control packets require exact fixed headers lengths and ids" {
  for pair in [(0x50, 0), (0x62, 1), (0x70, 2)] {
    let (header, kind) = pair
    for value in [1, 65535] {
      let id = PacketId::new(value).unwrap()
      let packet : Packet = match kind {
        0 => Pubrec(id)
        1 => Pubrel(id)
        _ => Pubcomp(id)
      }
      let bytes = Bytes::from_array([
        header.to_byte(),
        2,
        (value >> 8).to_byte(),
        value.to_byte(),
      ])
      assert_eq(encode_packet(packet), Ok(bytes))
      assert_eq(decode_packet(bytes), Ok(packet))
      assert_eq(validate_direction(packet, ClientToServer), Ok(()))
      assert_eq(validate_direction(packet, ServerToClient), Ok(()))
    }
    for flags in 0..<16 {
      if flags == (header & 15) {
        continue
      }
      assert_true(
        decode_packet(
          Bytes::from_array([((header & 0xf0) | flags).to_byte(), 2, 0, 1]),
        )
        is Err(_),
      )
    }
    for length in [0, 1, 3] {
      let bytes : Array[Byte] = [header.to_byte(), length.to_byte()]
      for _ in 0..<length {
        bytes.push(1)
      }
      assert_true(decode_packet(Bytes::from_array(bytes)) is Err(_))
    }
    assert_true(
      decode_packet(Bytes::from_array([header.to_byte(), 2, 0, 0]))
      is Err(InvalidPacketId(_)),
    )
    assert_true(
      decode_packet(Bytes::from_array([header.to_byte(), 2, 0])) is Err(_),
    )
    assert_true(
      decode_packet(Bytes::from_array([header.to_byte(), 2, 0, 1, 0]))
      is Err(TrailingBytes(_)),
    )
  }
  assert_true(decode_packet(b"\x6a\x02\x00\x01") is Err(InvalidFlags(_)))
  assert_true(decode_packet(b"\x36\x03\x00\x01a") is Err(_))
}

///|
test "qos2 will subscriptions and empty publications roundtrip" {
  round_trip(
    Connect({
      client_id: "q2",
      username: None,
      password: None,
      keep_alive: 0,
      clean_session: false,
      will: Some({
        topic: "will/q2",
        payload: b"offline",
        qos: QoS2,
        retain: true,
      }),
    }),
  )
  let id = PacketId::new(1).unwrap()
  round_trip(
    Subscribe({
      packet_id: id,
      subscriptions: [{ topic_filter: "q2/#", requested_qos: QoS2 }],
    }),
  )
  round_trip(Suback({ packet_id: id, return_codes: [GrantedQoS2] }))
  for dup in [false, true] {
    round_trip(
      Publish({
        topic: "q2",
        payload: b"",
        qos: QoS2,
        packet_id: Some(id),
        dup,
        retain: true,
      }),
    )
  }
  assert_true(
    encode_packet(
      Publish({
        topic: "q2",
        payload: b"",
        qos: QoS2,
        packet_id: None,
        dup: false,
        retain: false,
      }),
    )
    is Err(InvalidPacketId(_)),
  )
}
