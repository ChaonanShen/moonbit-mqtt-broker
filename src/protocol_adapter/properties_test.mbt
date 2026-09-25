///|
fn checked_properties(
  data : Bytes,
  location : PropertyLocation,
  direction : PacketDirection,
  max_bytes : Int,
  max_properties : Int,
) -> Result[Array[Property], WireError] {
  Ok(
    decode_properties(
      WireReader::new(data),
      location,
      direction,
      max_bytes,
      max_properties,
    ),
  ) catch {
    error => Err(error)
  }
}

///|
test "C-T02 MQTT5 properties preserve ordered duplicate User Property" {
  let values : Array[Property] = [
    { id: 0x26, value: PropertyValue::StringPair("a", "1") },
    { id: 0x26, value: PropertyValue::StringPair("a", "2") },
    { id: 0x21, value: PropertyValue::TwoByteValue(1) },
  ]
  let writer = WireWriter::new(100)
  encode_properties(writer, values, ConnectProperties, ClientToServer)
  let bytes = writer.finish()
  assert_eq(
    checked_properties(bytes, ConnectProperties, ClientToServer, 100, 3),
    Ok([
      { id: 0x21, value: PropertyValue::TwoByteValue(1) },
      { id: 0x26, value: PropertyValue::StringPair("a", "1") },
      { id: 0x26, value: PropertyValue::StringPair("a", "2") },
    ]),
  )
  assert_true(
    checked_properties(bytes, ConnectProperties, ClientToServer, 100, 2)
    is Err(WireLimitExceeded(_)),
  )
}

///|
test "C-T02 MQTT5 property location value and repetition rules" {
  assert_true(
    checked_properties(
      b"\x02\x21\x00",
      PublishProperties,
      ClientToServer,
      100,
      4,
    )
    is Err(InvalidWireValue(_)),
  )
  assert_true(
    checked_properties(
      b"\x04\x21\x00\x01\x21",
      ConnectProperties,
      ClientToServer,
      100,
      4,
    )
    is Err(Truncated(_)),
  )
  assert_true(
    checked_properties(
      b"\x06\x21\x00\x01\x21\x00\x02",
      ConnectProperties,
      ClientToServer,
      100,
      4,
    )
    is Err(InvalidWireValue(_)),
  )
  assert_true(
    checked_properties(
      b"\x03\x21\x00\x00",
      ConnectProperties,
      ClientToServer,
      100,
      4,
    )
    is Err(InvalidWireValue(_)),
  )
  assert_true(
    checked_properties(
      b"\x02\x17\x02",
      ConnectProperties,
      ClientToServer,
      100,
      4,
    )
    is Err(InvalidWireValue(_)),
  )
  assert_true(
    checked_properties(
      b"\x02\x0b\x01",
      PublishProperties,
      ClientToServer,
      100,
      4,
    )
    is Err(InvalidWireValue(_)),
  )
  assert_eq(
    checked_properties(
      b"\x02\x0b\x01",
      PublishProperties,
      ServerToClient,
      100,
      4,
    ),
    Ok([{ id: 0x0b, value: PropertyValue::VariableValue(1) }]),
  )
}

///|
test "C-T02 property encoding sorts IDs and keeps duplicate order" {
  let writer = WireWriter::new(100)
  encode_properties(
    writer,
    [
      { id: 0x26, value: PropertyValue::StringPair("k", "first") },
      { id: 0x21, value: PropertyValue::TwoByteValue(1) },
      { id: 0x26, value: PropertyValue::StringPair("k", "second") },
    ],
    ConnectProperties,
    ClientToServer,
  )
  let decoded = checked_properties(
    writer.finish(),
    ConnectProperties,
    ClientToServer,
    100,
    3,
  ).unwrap()
  assert_eq(decoded[0].id, 0x21)
  assert_eq(decoded[1].value, PropertyValue::StringPair("k", "first"))
  assert_eq(decoded[2].value, PropertyValue::StringPair("k", "second"))
}

///|
test "C-T02 all 27 MQTT5 property IDs have one registered wire kind" {
  let ids = [
    0x01, 0x02, 0x03, 0x08, 0x09, 0x0b, 0x11, 0x12, 0x13, 0x15, 0x16, 0x17, 0x18,
    0x19, 0x1a, 0x1c, 0x1f, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29,
    0x2a,
  ]
  assert_eq(ids.length(), 27)
  for id in ids {
    assert_true(property_kind(id) is Some(_))
  }
  for id in [0, 4, 7, 0x10, 0x20, 0x2b, 0xff] {
    assert_eq(property_kind(id), None)
  }
}

///|
test "C-T02 User Property direction matches every MQTT5 packet family" {
  for
    location in [
      PropertyLocation::ConnectProperties,
      PropertyLocation::WillProperties,
      PropertyLocation::SubscribeProperties,
      PropertyLocation::UnsubscribeProperties,
    ] {
    assert_true(property_allowed(0x26, location, ClientToServer))
    assert_false(property_allowed(0x26, location, ServerToClient))
  }
  for
    location in [
      PropertyLocation::ConnackProperties,
      PropertyLocation::SubackProperties,
      PropertyLocation::UnsubackProperties,
    ] {
    assert_false(property_allowed(0x26, location, ClientToServer))
    assert_true(property_allowed(0x26, location, ServerToClient))
  }
  for
    location in [
      PropertyLocation::PublishProperties,
      PropertyLocation::PubackProperties,
      PropertyLocation::PubrecProperties,
      PropertyLocation::PubrelProperties,
      PropertyLocation::PubcompProperties,
      PropertyLocation::DisconnectProperties,
      PropertyLocation::AuthProperties,
    ] {
    assert_true(property_allowed(0x26, location, ClientToServer))
    assert_true(property_allowed(0x26, location, ServerToClient))
  }
}
