///|
test "packet identifier validates mqtt range" {
  debug_inspect(
    PacketId::new(0),
    content=(
      #|Err(InvalidPacketId("packet identifier must be in 1..65535"))
    ),
  )
  inspect(PacketId::new(1).unwrap().value(), content="1")
  inspect(PacketId::new(65535).unwrap().value(), content="65535")
  debug_inspect(
    PacketId::new(65536),
    content=(
      #|Err(InvalidPacketId("packet identifier must be in 1..65535"))
    ),
  )
}

///|
test "connect keeps binary password and atomic will fields" {
  let connect : ConnectPacket = {
    client_id: "m0-client",
    username: Some("user"),
    password: Some(b"\x00secret"),
    keep_alive: 60,
    clean_session: true,
    will: Some({
      topic: "clients/m0/status",
      payload: b"offline",
      qos: QoS::QoS1,
      retain: true,
    }),
  }
  let packet = Packet::Connect(connect)
  match packet {
    Packet::Connect(connect) => {
      assert_eq(connect.password, Some(b"\x00secret"))
      assert_eq(connect.will.unwrap().qos, QoS::QoS1)
    }
    _ => fail("expected CONNECT")
  }
}

///|
test "packet model compares complete publish semantics" {
  let id = PacketId::new(42).unwrap()
  let left = Packet::Publish({
    topic: "a/b",
    payload: b"payload",
    qos: QoS::QoS1,
    packet_id: Some(id),
    dup: true,
    retain: false,
  })
  let right = Packet::Publish({
    topic: "a/b",
    payload: b"payload",
    qos: QoS::QoS1,
    packet_id: Some(id),
    dup: true,
    retain: false,
  })
  assert_eq(left, right)
}

///|
test "direction validation covers asymmetric control packets" {
  let id = PacketId::new(7).unwrap()
  assert_eq(
    validate_direction(Packet::Pingreq, PacketDirection::ClientToServer),
    Ok(()),
  )
  assert_eq(
    validate_direction(Packet::Pingresp, PacketDirection::ServerToClient),
    Ok(()),
  )
  assert_eq(
    validate_direction(Packet::Puback(id), PacketDirection::ClientToServer),
    Ok(()),
  )
  assert_eq(
    validate_direction(Packet::Puback(id), PacketDirection::ServerToClient),
    Ok(()),
  )
  debug_inspect(
    validate_direction(Packet::Pingresp, PacketDirection::ClientToServer),
    content=(
      #|Err(InvalidDirection("packet is not valid in this direction"))
    ),
  )
  debug_inspect(
    validate_direction(Packet::Disconnect, PacketDirection::ServerToClient),
    content=(
      #|Err(InvalidDirection("packet is not valid in this direction"))
    ),
  )
}
