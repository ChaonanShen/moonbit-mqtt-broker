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
    Ok(values),
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
