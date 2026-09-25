///|
fn validate_canonical_frame(frame : Bytes) -> Result[Unit, CodecError] {
  if frame.length() < 2 {
    return Err(InvalidPacketShape("fixed header is truncated"))
  }
  let packet_type = (frame[0].to_int() >> 4) & 0x0f
  if packet_type == 0 || packet_type == 15 {
    return Err(UnsupportedPacketType("reserved MQTT control packet type"))
  }
  if packet_type == 6 && frame[0] != 0x62 {
    return Err(InvalidFlags("PUBREL fixed header must be 0x62"))
  }
  let mut value = 0
  let mut multiplier = 1
  let mut index = 1
  let mut digits = 0
  for ;; {
    if index >= frame.length() {
      return Err(InvalidPacketShape("remaining length is truncated"))
    }
    let encoded = frame[index].to_int()
    digits = digits + 1
    value = value + (encoded & 0x7f) * multiplier
    index = index + 1
    if (encoded & 0x80) == 0 {
      break
    }
    if digits == 4 {
      return Err(InvalidRemainingLength("remaining length exceeds four bytes"))
    }
    multiplier = multiplier * 128
  }
  let minimal_digits = if value < 128 {
    1
  } else if value < 16384 {
    2
  } else if value < 2097152 {
    3
  } else {
    4
  }
  if digits != minimal_digits {
    return Err(
      InvalidRemainingLength("remaining length is not minimally encoded"),
    )
  }
  let total = index + value
  if total < frame.length() {
    Err(TrailingBytes("complete packet contains trailing bytes"))
  } else if total > frame.length() {
    Err(InvalidPacketShape("packet body is truncated"))
  } else {
    Ok(())
  }
}

///|
fn legacy_codec_error(error : WireError) -> CodecError {
  match error {
    Truncated(_) | InvalidWireValue(_) =>
      InvalidPacketShape("invalid packet shape")
    MalformedVariableInteger(_) =>
      InvalidRemainingLength("invalid variable integer")
    InvalidWireString(_) => InvalidUtf8("invalid UTF-8 string")
    WireLimitExceeded(_) => PacketTooLarge("packet exceeds wire limit")
    LegacyCodec(error) => error
    WireInvalidFlags(_) => InvalidFlags("invalid fixed or CONNECT flags")
    WireInvalidPacketId(_) =>
      InvalidPacketId("packet identifier must be nonzero")
  }
}

///|
fn read_legacy_id(reader : WireReader) -> PacketId raise WireError {
  let position = reader.position()
  match PacketId::new(reader.u16()) {
    Ok(value) => value
    Err(_) => raise WireInvalidPacketId(position)
  }
}

///|
fn read_legacy_qos(value : Int, position : Int) -> QoS raise WireError {
  match value {
    0 => QoS0
    1 => QoS1
    2 => QoS2
    _ => raise InvalidWireValue(position)
  }
}

///|
fn decode_v311_body(
  kind : Int,
  flags : Int,
  reader : WireReader,
) -> Packet raise WireError {
  if kind != 3 &&
    flags != (if kind == 6 || kind == 8 || kind == 10 { 2 } else { 0 }) {
    raise WireInvalidFlags(0)
  }
  match kind {
    1 => {
      if reader.utf8() != "MQTT" {
        raise InvalidWireValue(reader.position())
      }
      if reader.u8() != 4 {
        raise InvalidWireValue(reader.position())
      }
      let connect_flags = reader.u8()
      if (connect_flags & 1) != 0 ||
        ((connect_flags & 0x40) != 0 && (connect_flags & 0x80) == 0) {
        raise WireInvalidFlags(reader.position())
      }
      let has_will = (connect_flags & 4) != 0
      let will_qos_bits = (connect_flags >> 3) & 3
      let will_retain = (connect_flags & 0x20) != 0
      if !has_will && (will_qos_bits != 0 || will_retain) {
        raise WireInvalidFlags(reader.position())
      }
      let will_qos = read_legacy_qos(will_qos_bits, reader.position())
      let keep_alive = reader.u16()
      let client_id = reader.utf8()
      let will = if has_will {
        let topic = reader.utf8()
        if !valid_topic_name(topic, false) {
          raise InvalidWireValue(reader.position())
        }
        let payload = reader.binary16()
        Some({ topic, payload, qos: will_qos, retain: will_retain })
      } else {
        None
      }
      let username = if (connect_flags & 0x80) != 0 {
        Some(reader.utf8())
      } else {
        None
      }
      let password = if (connect_flags & 0x40) != 0 {
        Some(reader.binary16())
      } else {
        None
      }
      reader.finish()
      Connect({
        client_id,
        username,
        password,
        keep_alive,
        clean_session: (connect_flags & 2) != 0,
        will,
      })
    }
    2 => {
      let ack_flags = reader.u8()
      let code = reader.u8()
      reader.finish()
      if ack_flags > 1 || code > 5 || (code != 0 && ack_flags != 0) {
        raise InvalidWireValue(reader.position())
      }
      let return_code = match code {
        0 => Accepted
        1 => UnacceptableProtocolVersion
        2 => IdentifierRejected
        3 => ServerUnavailable
        4 => BadUsernameOrPassword
        _ => NotAuthorized
      }
      Connack({ session_present: ack_flags == 1, return_code })
    }
    3 => {
      let qos = read_legacy_qos((flags >> 1) & 3, 0)
      let dup = (flags & 8) != 0
      if qos == QoS0 && dup {
        raise WireInvalidFlags(0)
      }
      let topic = reader.utf8()
      if !valid_topic_name(topic, false) {
        raise InvalidWireValue(reader.position())
      }
      let packet_id = if qos == QoS0 {
        None
      } else {
        Some(read_legacy_id(reader))
      }
      let payload = reader.raw(reader.remaining())
      Publish({ topic, payload, qos, packet_id, dup, retain: (flags & 1) != 0 })
    }
    4 | 5 | 6 | 7 | 11 => {
      let packet_id = read_legacy_id(reader)
      reader.finish()
      match kind {
        4 => Puback(packet_id)
        5 => Pubrec(packet_id)
        6 => Pubrel(packet_id)
        7 => Pubcomp(packet_id)
        _ => Unsuback(packet_id)
      }
    }
    8 => {
      let packet_id = read_legacy_id(reader)
      let subscriptions : Array[Subscription] = []
      while reader.remaining() > 0 {
        let topic_filter = reader.utf8()
        if !valid_topic_filter(topic_filter) {
          raise InvalidWireValue(reader.position())
        }
        let qos = read_legacy_qos(reader.u8(), reader.position())
        subscriptions.push({ topic_filter, requested_qos: qos })
      }
      if subscriptions.length() == 0 {
        raise InvalidWireValue(reader.position())
      }
      Subscribe({ packet_id, subscriptions })
    }
    9 => {
      let packet_id = read_legacy_id(reader)
      let return_codes : Array[SubackReturnCode] = []
      while reader.remaining() > 0 {
        let code = reader.u8()
        return_codes.push(
          match code {
            0 => GrantedQoS0
            1 => GrantedQoS1
            2 => GrantedQoS2
            0x80 => Failure
            _ => raise InvalidWireValue(reader.position())
          },
        )
      }
      if return_codes.length() == 0 {
        raise InvalidWireValue(reader.position())
      }
      Suback({ packet_id, return_codes })
    }
    10 => {
      let packet_id = read_legacy_id(reader)
      let topic_filters : Array[String] = []
      while reader.remaining() > 0 {
        let topic_filter = reader.utf8()
        if !valid_topic_filter(topic_filter) {
          raise InvalidWireValue(reader.position())
        }
        topic_filters.push(topic_filter)
      }
      if topic_filters.length() == 0 {
        raise InvalidWireValue(reader.position())
      }
      Unsubscribe({ packet_id, topic_filters })
    }
    12 => {
      reader.finish()
      Pingreq
    }
    13 => {
      reader.finish()
      Pingresp
    }
    14 => {
      reader.finish()
      Disconnect
    }
    _ => raise InvalidWireValue(0)
  }
}

///|
pub fn decode_v311(frame : Bytes) -> Result[Packet, CodecError] {
  match validate_canonical_frame(frame) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let result : Result[Packet, WireError] = try {
    let header = WireReader::new(frame)
    let first = header.u8()
    let kind = first >> 4
    let flags = first & 15
    let body_length = header.vbi()
    if body_length != header.remaining() {
      raise InvalidWireValue(header.position())
    }
    let body = WireReader::bounded(frame, header.position(), frame.length())
    Ok(decode_v311_body(kind, flags, body))
  } catch {
    error => Err(error)
  }
  match result {
    Ok(packet) => Ok(packet)
    Err(error) => Err(legacy_codec_error(error))
  }
}
