///|
pub(all) enum PropertyLocation {
  ConnectProperties
  ConnackProperties
  PublishProperties
  WillProperties
  PubackProperties
  PubrecProperties
  PubrelProperties
  PubcompProperties
  SubscribeProperties
  SubackProperties
  UnsubscribeProperties
  UnsubackProperties
  DisconnectProperties
  AuthProperties
} derive(Eq, Debug)

///|
pub(all) enum PropertyValue {
  ByteValue(Int)
  TwoByteValue(Int)
  FourByteValue(UInt)
  VariableValue(Int)
  StringValue(String)
  BinaryValue(Bytes)
  StringPair(String, String)
} derive(Eq, Debug)

///|
pub(all) struct Property {
  id : Int
  value : PropertyValue
} derive(Eq, Debug)

///|
pub(all) enum PropertyKind {
  PropertyByte
  PropertyTwoByte
  PropertyFourByte
  PropertyVariable
  PropertyString
  PropertyBinary
  PropertyStringPair
} derive(Eq, Debug)

///|
/// One registry supplies the wire type, placement, and cardinality rules.
pub fn property_kind(id : Int) -> PropertyKind? {
  match id {
    0x01 | 0x17 | 0x19 | 0x24 | 0x25 | 0x28 | 0x29 | 0x2a => Some(PropertyByte)
    0x13 | 0x21 | 0x22 | 0x23 => Some(PropertyTwoByte)
    0x02 | 0x11 | 0x18 | 0x27 => Some(PropertyFourByte)
    0x0b => Some(PropertyVariable)
    0x03 | 0x08 | 0x12 | 0x15 | 0x1a | 0x1c | 0x1f => Some(PropertyString)
    0x09 | 0x16 => Some(PropertyBinary)
    0x26 => Some(PropertyStringPair)
    _ => None
  }
}

///|
pub fn property_repeated(id : Int, location : PropertyLocation) -> Bool {
  id == 0x26 || (id == 0x0b && location == PublishProperties)
}

///|
pub fn property_allowed(
  id : Int,
  location : PropertyLocation,
  direction : PacketDirection,
) -> Bool {
  match (id, location, direction) {
    (0x01 | 0x02 | 0x03 | 0x08 | 0x09, PublishProperties, _) => true
    (0x01 | 0x02 | 0x03 | 0x08 | 0x09 | 0x18, WillProperties, ClientToServer) =>
      true
    (0x23, PublishProperties, _) => true
    (0x0b, SubscribeProperties, ClientToServer) => true
    (0x0b, PublishProperties, ServerToClient) => true
    (0x11 | 0x15 | 0x16 | 0x21 | 0x22 | 0x27, ConnectProperties, ClientToServer) =>
      true
    (
      0x11
      | 0x12
      | 0x13
      | 0x15
      | 0x16
      | 0x1a
      | 0x1c
      | 0x21
      | 0x22
      | 0x24
      | 0x25
      | 0x27
      | 0x28
      | 0x29
      | 0x2a,
      ConnackProperties,
      ServerToClient,
    ) => true
    (0x11, DisconnectProperties, ClientToServer) => true
    (0x17 | 0x19, ConnectProperties, ClientToServer) => true
    (0x1c, DisconnectProperties, ServerToClient) => true
    (0x1f, ConnackProperties, ServerToClient) => true
    (
      0x1f,
      PubackProperties
      | PubrecProperties
      | PubrelProperties
      | PubcompProperties
      | DisconnectProperties
      | AuthProperties,
      _,
    ) => true
    (0x1f, SubackProperties | UnsubackProperties, ServerToClient) => true
    (0x15 | 0x16, AuthProperties, _) => true
    (0x26, _, _) => true
    _ => false
  }
}

///|
fn validate_property_value(
  property : Property,
  location : PropertyLocation,
  direction : PacketDirection,
) -> Unit raise WireError {
  let id = property.id
  if !property_allowed(id, location, direction) {
    raise InvalidWireValue(0)
  }
  let kind = match property_kind(id) {
    Some(value) => value
    None => raise InvalidWireValue(0)
  }
  let type_valid = match (kind, property.value) {
    (PropertyByte, ByteValue(value)) => value >= 0 && value <= 255
    (PropertyTwoByte, TwoByteValue(value)) => value >= 0 && value <= 65535
    (PropertyFourByte, FourByteValue(_)) => true
    (PropertyVariable, VariableValue(value)) => value >= 0 && value <= 268435455
    (PropertyString, StringValue(_)) => true
    (PropertyBinary, BinaryValue(_)) => true
    (PropertyStringPair, StringPair(_, _)) => true
    _ => false
  }
  if !type_valid {
    raise InvalidWireValue(0)
  }
  match property.value {
    ByteValue(value) if id == 0x01 ||
      id == 0x17 ||
      id == 0x19 ||
      id == 0x24 ||
      id == 0x25 ||
      id == 0x28 ||
      id == 0x29 ||
      id == 0x2a => if value > 1 { raise InvalidWireValue(0) }
    TwoByteValue(0) if id == 0x21 || id == 0x23 => raise InvalidWireValue(0)
    FourByteValue(0U) if id == 0x27 => raise InvalidWireValue(0)
    VariableValue(0) if id == 0x0b => raise InvalidWireValue(0)
    StringValue(value) if id == 0x08 =>
      if !valid_topic_name(value, false) {
        raise InvalidWireValue(0)
      }
    _ => ()
  }
}

///|
pub fn validate_properties(
  properties : Array[Property],
  location : PropertyLocation,
  direction : PacketDirection,
  max_properties : Int,
) -> Unit raise WireError {
  if properties.length() > max_properties {
    raise WireLimitExceeded(0)
  }
  let seen : Map[Int, Bool] = Map([])
  let mut auth_method = false
  let mut auth_data = false
  for property in properties {
    validate_property_value(property, location, direction)
    if seen.contains(property.id) && !property_repeated(property.id, location) {
      raise InvalidWireValue(0)
    }
    seen.set(property.id, true)
    if property.id == 0x15 {
      auth_method = true
    }
    if property.id == 0x16 {
      auth_data = true
    }
  }
  if auth_data && !auth_method && location == ConnectProperties {
    raise InvalidWireValue(0)
  }
}

///|
pub fn decode_properties(
  reader : WireReader,
  location : PropertyLocation,
  direction : PacketDirection,
  max_bytes : Int,
  max_properties : Int,
) -> Array[Property] raise WireError {
  let length = reader.vbi()
  if length > max_bytes {
    raise WireLimitExceeded(reader.position())
  }
  if length > reader.remaining() {
    raise Truncated(reader.position())
  }
  let end = reader.position() + length
  let section = WireReader::bounded(reader.data, reader.position(), end)
  let properties : Array[Property] = []
  while section.position() < end {
    if properties.length() >= max_properties {
      raise WireLimitExceeded(section.position())
    }
    let id = section.u8()
    let kind = match property_kind(id) {
      Some(value) => value
      None => raise InvalidWireValue(section.position() - 1)
    }
    if !property_allowed(id, location, direction) {
      raise InvalidWireValue(section.position() - 1)
    }
    let value = match kind {
      PropertyByte => ByteValue(section.u8())
      PropertyTwoByte => TwoByteValue(section.u16())
      PropertyFourByte => FourByteValue(section.u32())
      PropertyVariable => VariableValue(section.vbi())
      PropertyString => StringValue(section.utf8())
      PropertyBinary => BinaryValue(section.binary16())
      PropertyStringPair => StringPair(section.utf8(), section.utf8())
    }
    if section.position() > end {
      raise Truncated(end)
    }
    properties.push({ id, value })
  }
  validate_properties(properties, location, direction, max_properties)
  reader.offset = end
  properties
}

///|
pub fn encode_properties(
  writer : WireWriter,
  properties : Array[Property],
  location : PropertyLocation,
  direction : PacketDirection,
) -> Unit raise WireError {
  validate_properties(properties, location, direction, 65535)
  let body = WireWriter::new(writer.max_bytes)
  for property in properties {
    body.u8(property.id)
    match property.value {
      ByteValue(value) => body.u8(value)
      TwoByteValue(value) => body.u16(value)
      FourByteValue(value) => body.u32(value)
      VariableValue(value) => body.vbi(value)
      StringValue(value) => body.utf8(value)
      BinaryValue(value) => body.binary16(value)
      StringPair(first, second) => {
        body.utf8(first)
        body.utf8(second)
      }
    }
  }
  writer.vbi(body.length())
  writer.raw(body.finish())
}
