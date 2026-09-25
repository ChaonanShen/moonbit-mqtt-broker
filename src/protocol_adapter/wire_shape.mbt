///|
pub(all) struct DecodeShape {
  mut string_count : Int
  mut string_bytes : Int
  mut binary_count : Int
  mut binary_bytes : Int
  mut property_count : Int
  mut entry_count : Int
  mut payload_bytes : Int
} derive(Eq, Debug)

///|
pub fn DecodeShape::logical_cost(self : DecodeShape) -> Int64 {
  128L +
  self.string_count.to_int64() * 32L +
  self.string_bytes.to_int64() * 2L +
  self.binary_count.to_int64() * 24L +
  self.binary_bytes.to_int64() +
  self.property_count.to_int64() * 96L +
  self.entry_count.to_int64() * 96L +
  self.payload_bytes.to_int64() +
  64L
}

///|
fn scan_v5_string(
  reader : WireReader,
  shape : DecodeShape,
) -> Unit raise WireError {
  let bytes = reader.u16()
  reader.skip(bytes)
  shape.string_count += 1
  shape.string_bytes += bytes
}

///|
fn scan_v5_binary(
  reader : WireReader,
  shape : DecodeShape,
) -> Unit raise WireError {
  let bytes = reader.u16()
  reader.skip(bytes)
  shape.binary_count += 1
  shape.binary_bytes += bytes
}

///|
fn scan_v5_properties(
  reader : WireReader,
  shape : DecodeShape,
  location : PropertyLocation,
  direction : PacketDirection,
  limits : DecodeLimits,
) -> Unit raise WireError {
  let length = reader.vbi()
  if length > limits.max_property_bytes || length > reader.remaining() {
    raise WireLimitExceeded(reader.position())
  }
  let end = reader.position() + length
  let mut section_count = 0
  while reader.position() < end {
    let id = reader.u8()
    let kind = match property_kind(id) {
      Some(value) if property_allowed(id, location, direction) => value
      _ => raise InvalidWireValue(reader.position() - 1)
    }
    section_count += 1
    shape.property_count += 1
    if section_count > limits.max_user_properties + 27 {
      raise WireLimitExceeded(reader.position())
    }
    match kind {
      PropertyByte => ignore(reader.u8())
      PropertyTwoByte => ignore(reader.u16())
      PropertyFourByte => ignore(reader.u32())
      PropertyVariable => ignore(reader.vbi())
      PropertyString => scan_v5_string(reader, shape)
      PropertyBinary => scan_v5_binary(reader, shape)
      PropertyStringPair => {
        scan_v5_string(reader, shape)
        scan_v5_string(reader, shape)
      }
    }
    if reader.position() > end {
      raise InvalidWireValue(end)
    }
  }
  if reader.position() != end {
    raise InvalidWireValue(end)
  }
}

///|
/// First-pass shape and cost scan. It skips strings and payload without
/// materializing them; the decoder performs UTF-8 and semantic validation
/// after the caller has reserved the returned logical cost.
pub fn scan_v5_frame_shape(
  frame : Bytes,
  direction : PacketDirection,
  limits : DecodeLimits,
) -> Result[DecodeShape, WireError] {
  try {
    if frame.length() < 2 || frame.length() > limits.max_packet_bytes {
      raise WireLimitExceeded(0)
    }
    let reader = WireReader::new(frame)
    let first = reader.u8()
    let kind = first >> 4
    let flags = first & 15
    if !v5_direction_allowed(kind, direction) {
      raise InvalidWireValue(0)
    }
    let declared = reader.vbi()
    if declared != reader.remaining() {
      raise InvalidWireValue(reader.position())
    }
    if kind == 3 {
      let qos = (flags >> 1) & 3
      if qos == 3 || (qos == 0 && (flags & 8) != 0) {
        raise InvalidWireValue(0)
      }
    } else if flags !=
      (if kind == 6 || kind == 8 || kind == 10 { 2 } else { 0 }) {
      raise InvalidWireValue(0)
    }
    let shape : DecodeShape = {
      string_count: 0,
      string_bytes: 0,
      binary_count: 0,
      binary_bytes: 0,
      property_count: 0,
      entry_count: 0,
      payload_bytes: 0,
    }
    match kind {
      1 => {
        scan_v5_string(reader, shape)
        ignore(reader.u8())
        let connect_flags = reader.u8()
        ignore(reader.u16())
        scan_v5_properties(reader, shape, ConnectProperties, direction, limits)
        scan_v5_string(reader, shape)
        if (connect_flags & 4) != 0 {
          scan_v5_properties(reader, shape, WillProperties, direction, limits)
          scan_v5_string(reader, shape)
          scan_v5_binary(reader, shape)
        }
        if (connect_flags & 0x80) != 0 {
          scan_v5_string(reader, shape)
        }
        if (connect_flags & 0x40) != 0 {
          scan_v5_binary(reader, shape)
        }
      }
      2 => {
        ignore(reader.u8())
        ignore(reader.u8())
        scan_v5_properties(reader, shape, ConnackProperties, direction, limits)
      }
      3 => {
        scan_v5_string(reader, shape)
        if ((flags >> 1) & 3) > 0 {
          ignore(reader.u16())
        }
        scan_v5_properties(reader, shape, PublishProperties, direction, limits)
        shape.payload_bytes = reader.remaining()
        reader.skip(reader.remaining())
      }
      4 | 5 | 6 | 7 => {
        ignore(reader.u16())
        if reader.remaining() > 0 {
          ignore(reader.u8())
        }
        if reader.remaining() > 0 {
          let location = match kind {
            4 => PubackProperties
            5 => PubrecProperties
            6 => PubrelProperties
            _ => PubcompProperties
          }
          scan_v5_properties(reader, shape, location, direction, limits)
        }
      }
      8 | 10 => {
        ignore(reader.u16())
        scan_v5_properties(
          reader,
          shape,
          if kind == 8 {
            SubscribeProperties
          } else {
            UnsubscribeProperties
          },
          direction,
          limits,
        )
        while reader.remaining() > 0 {
          if shape.entry_count >= limits.max_subscription_entries {
            raise WireLimitExceeded(reader.position())
          }
          scan_v5_string(reader, shape)
          if kind == 8 {
            ignore(reader.u8())
          }
          shape.entry_count += 1
        }
      }
      9 | 11 => {
        ignore(reader.u16())
        scan_v5_properties(
          reader,
          shape,
          if kind == 9 {
            SubackProperties
          } else {
            UnsubackProperties
          },
          direction,
          limits,
        )
        shape.entry_count = reader.remaining()
        reader.skip(reader.remaining())
      }
      12 | 13 => ()
      14 | 15 => {
        if reader.remaining() > 0 {
          ignore(reader.u8())
        }
        if reader.remaining() > 0 {
          scan_v5_properties(
            reader,
            shape,
            if kind == 14 {
              DisconnectProperties
            } else {
              AuthProperties
            },
            direction,
            limits,
          )
        }
      }
      _ => raise InvalidWireValue(0)
    }
    reader.finish()
    Ok(shape)
  } catch {
    error => Err(error)
  }
}
