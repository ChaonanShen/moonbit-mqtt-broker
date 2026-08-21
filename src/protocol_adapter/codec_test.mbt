///|
fn round_trip(packet : Packet) -> Unit raise {
  let encoded = encode_packet(packet).unwrap()
  assert_eq(decode_packet(encoded), Ok(packet))
}

///|
test "candidate adapter round trips all m0 packet families" {
  let id = PacketId::new(42).unwrap()
  round_trip(
    Packet::Connect({
      client_id: "client-42",
      username: Some("user"),
      password: Some(b"\x00password"),
      keep_alive: 60,
      clean_session: true,
      will: Some({
        topic: "status/client-42",
        payload: b"offline",
        qos: QoS::QoS1,
        retain: true,
      }),
    }),
  )
  round_trip(
    Packet::Connack({
      session_present: false,
      return_code: ConnectReturnCode::Accepted,
    }),
  )
  round_trip(
    Packet::Publish({
      topic: "sensors/temperature",
      payload: b"21.5",
      qos: QoS::QoS1,
      packet_id: Some(id),
      dup: true,
      retain: true,
    }),
  )
  round_trip(Packet::Puback(id))
  round_trip(
    Packet::Subscribe({
      packet_id: id,
      subscriptions: [
        { topic_filter: "sensors/+", requested_qos: QoS::QoS0 },
        { topic_filter: "alerts/#", requested_qos: QoS::QoS1 },
      ],
    }),
  )
  round_trip(
    Packet::Suback({
      packet_id: id,
      return_codes: [
        SubackReturnCode::GrantedQoS0,
        SubackReturnCode::GrantedQoS1,
        SubackReturnCode::Failure,
      ],
    }),
  )
  round_trip(
    Packet::Unsubscribe({
      packet_id: id,
      topic_filters: ["sensors/+", "alerts/#"],
    }),
  )
  round_trip(Packet::Unsuback(id))
  round_trip(Packet::Pingreq)
  round_trip(Packet::Pingresp)
  round_trip(Packet::Disconnect)
}

///|
test "adapter classifies malformed packets and qos2" {
  assert_true(decode_packet(b"\xc0\x00\x00") is Err(TrailingBytes(_)))
  assert_true(decode_packet(b"\xc0\x80\x00") is Err(InvalidRemainingLength(_)))
  assert_true(decode_packet(b"\xc1\x00") is Err(InvalidFlags(_)))
  assert_true(decode_packet(b"\x40\x02\x00\x00") is Err(InvalidPacketId(_)))
  assert_eq(
    encode_packet(
      Packet::Publish({
        topic: "qos2",
        payload: b"unsupported",
        qos: QoS::QoS2,
        packet_id: Some(PacketId::new(1).unwrap()),
        dup: false,
        retain: false,
      }),
    ),
    Err(CodecError::UnsupportedQoS("QoS 2 is not supported")),
  )
}

///|
test "one thousand candidate round trips preserve semantics" {
  for index in 1..<=1000 {
    let qos = if index % 2 == 0 { QoS::QoS0 } else { QoS::QoS1 }
    let packet_id = if qos == QoS::QoS0 {
      None
    } else {
      Some(PacketId::new(index % 65535 + 1).unwrap())
    }
    round_trip(
      Packet::Publish({
        topic: "gate/topic/\{index % 17}",
        payload: Bytes::from_array([
          (index & 0xff).to_byte(),
          ((index >> 8) & 0xff).to_byte(),
        ]),
        qos,
        packet_id,
        dup: qos == QoS::QoS1 && index % 3 == 0,
        retain: index % 5 == 0,
      }),
    )
  }
}
