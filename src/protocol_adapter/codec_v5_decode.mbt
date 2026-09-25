///|
fn read_packet_id(reader : WireReader) -> PacketId raise WireError {
  let start = reader.position()
  match PacketId::new(reader.u16()) {
    Ok(value) => value
    Err(_) => raise InvalidWireValue(start)
  }
}

///|
fn read_qos(bits : Int, offset : Int) -> QoS raise WireError {
  match bits {
    0 => QoS0
    1 => QoS1
    2 => QoS2
    _ => raise InvalidWireValue(offset)
  }
}

///|
fn v5_direction_allowed(kind : Int, direction : PacketDirection) -> Bool {
  match (kind, direction) {
    (1 | 8 | 10 | 12, ClientToServer) => true
    (2 | 9 | 11 | 13, ServerToClient) => true
    (3 | 4 | 5 | 6 | 7 | 14 | 15, _) => true
    _ => false
  }
}

///|
fn read_v5_properties(
  reader : WireReader,
  location : PropertyLocation,
  direction : PacketDirection,
  limits : DecodeLimits,
) -> Array[Property] raise WireError {
  let properties = decode_properties(
    reader,
    location,
    direction,
    limits.max_property_bytes,
    limits.max_user_properties + 27,
  )
  let mut user_count = 0
  for property in properties {
    if property.id == 0x26 {
      user_count += 1
    }
  }
  if user_count > limits.max_user_properties {
    raise WireLimitExceeded(reader.position())
  }
  properties
}

///|
fn read_v5_ack(
  reader : WireReader,
  location : PropertyLocation,
  reason_kind : ReasonPacketKind,
  direction : PacketDirection,
  limits : DecodeLimits,
) -> AckV5 raise WireError {
  let packet_id = read_packet_id(reader)
  let reason = if reader.remaining() == 0 { 0 } else { reader.u8() }
  if !reason_allowed(reason_kind, direction, reason) {
    raise InvalidWireValue(reader.position())
  }
  let properties = if reader.remaining() == 0 {
    []
  } else {
    read_v5_properties(reader, location, direction, limits)
  }
  reader.finish()
  { packet_id, reason, properties }
}

///|
fn read_v5_disconnect_or_auth(
  reader : WireReader,
  location : PropertyLocation,
  reason_kind : ReasonPacketKind,
  direction : PacketDirection,
  limits : DecodeLimits,
) -> (Int, Array[Property]) raise WireError {
  let reason = if reader.remaining() == 0 { 0 } else { reader.u8() }
  if !reason_allowed(reason_kind, direction, reason) {
    raise InvalidWireValue(reader.position())
  }
  let properties = if reader.remaining() == 0 {
    []
  } else {
    read_v5_properties(reader, location, direction, limits)
  }
  reader.finish()
  (reason, properties)
}

///|
fn decode_v5_body(
  kind : Int,
  flags : Int,
  reader : WireReader,
  direction : PacketDirection,
  limits : DecodeLimits,
) -> PacketV5 raise WireError {
  if !v5_direction_allowed(kind, direction) {
    raise InvalidWireValue(0)
  }
  if kind == 3 {
    let qos_bits = (flags >> 1) & 3
    let qos = read_qos(qos_bits, 0)
    let dup = (flags & 8) != 0
    if qos == QoS0 && dup {
      raise InvalidWireValue(0)
    }
    let topic = reader.utf8()
    if !valid_topic_name(topic, true) {
      raise InvalidWireValue(reader.position())
    }
    let packet_id = if qos == QoS0 {
      None
    } else {
      Some(read_packet_id(reader))
    }
    let properties = read_v5_properties(
      reader,
      PublishProperties,
      direction,
      limits,
    )
    let payload = reader.raw(reader.remaining())
    return Publish5({
      topic,
      payload,
      qos,
      packet_id,
      dup,
      retain: (flags & 1) != 0,
      properties,
    })
  }
  if flags != (if kind == 6 || kind == 8 || kind == 10 { 2 } else { 0 }) {
    raise InvalidWireValue(0)
  }
  match kind {
    1 => {
      if reader.utf8() != "MQTT" || reader.u8() != 5 {
        raise InvalidWireValue(reader.position())
      }
      let connect_flags = reader.u8()
      if (connect_flags & 1) != 0 {
        raise InvalidWireValue(reader.position())
      }
      let will_flag = (connect_flags & 4) != 0
      let will_qos_bits = (connect_flags >> 3) & 3
      let will_retain = (connect_flags & 0x20) != 0
      if !will_flag && (will_qos_bits != 0 || will_retain) {
        raise InvalidWireValue(reader.position())
      }
      let will_qos = read_qos(will_qos_bits, reader.position())
      let keep_alive = reader.u16()
      let properties = read_v5_properties(
        reader,
        ConnectProperties,
        direction,
        limits,
      )
      let client_id = reader.utf8()
      let will = if will_flag {
        let will_properties = read_v5_properties(
          reader,
          WillProperties,
          direction,
          limits,
        )
        let topic = reader.utf8()
        if !valid_topic_name(topic, false) {
          raise InvalidWireValue(reader.position())
        }
        let payload = reader.binary16()
        Some({
          topic,
          payload,
          qos: will_qos,
          retain: will_retain,
          properties: will_properties,
        })
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
      Connect5({
        client_id,
        username,
        password,
        keep_alive,
        clean_start: (connect_flags & 2) != 0,
        properties,
        will,
      })
    }
    2 => {
      let ack_flags = reader.u8()
      if ack_flags > 1 {
        raise InvalidWireValue(reader.position())
      }
      let reason = reader.u8()
      if !reason_allowed(ConnackReason, direction, reason) ||
        (reason != 0 && ack_flags != 0) {
        raise InvalidWireValue(reader.position())
      }
      let properties = read_v5_properties(
        reader,
        ConnackProperties,
        direction,
        limits,
      )
      reader.finish()
      Connack5({ session_present: ack_flags == 1, reason, properties })
    }
    4 =>
      Puback5(
        read_v5_ack(reader, PubackProperties, PubackReason, direction, limits),
      )
    5 =>
      Pubrec5(
        read_v5_ack(reader, PubrecProperties, PubrecReason, direction, limits),
      )
    6 =>
      Pubrel5(
        read_v5_ack(reader, PubrelProperties, PubrelReason, direction, limits),
      )
    7 =>
      Pubcomp5(
        read_v5_ack(reader, PubcompProperties, PubcompReason, direction, limits),
      )
    8 => {
      let packet_id = read_packet_id(reader)
      let properties = read_v5_properties(
        reader,
        SubscribeProperties,
        direction,
        limits,
      )
      let subscriptions : Array[SubscriptionV5] = []
      while reader.remaining() > 0 {
        if subscriptions.length() >= limits.max_subscription_entries {
          raise WireLimitExceeded(reader.position())
        }
        let topic_filter = reader.utf8()
        if !valid_topic_filter(topic_filter) {
          raise InvalidWireValue(reader.position())
        }
        let options = reader.u8()
        if (options & 0xc0) != 0 || ((options >> 4) & 3) > 2 {
          raise InvalidWireValue(reader.position())
        }
        let requested_qos = read_qos(options & 3, reader.position())
        subscriptions.push({
          topic_filter,
          requested_qos,
          no_local: (options & 4) != 0,
          retain_as_published: (options & 8) != 0,
          retain_handling: (options >> 4) & 3,
        })
      }
      if subscriptions.length() == 0 {
        raise InvalidWireValue(reader.position())
      }
      Subscribe5({ packet_id, properties, subscriptions })
    }
    9 => {
      let packet_id = read_packet_id(reader)
      let properties = read_v5_properties(
        reader,
        SubackProperties,
        direction,
        limits,
      )
      let reasons : Array[Int] = []
      while reader.remaining() > 0 {
        let reason = reader.u8()
        if !reason_allowed(SubackReason, direction, reason) {
          raise InvalidWireValue(reader.position())
        }
        reasons.push(reason)
      }
      if reasons.length() == 0 {
        raise InvalidWireValue(reader.position())
      }
      Suback5({ packet_id, properties, reasons })
    }
    10 => {
      let packet_id = read_packet_id(reader)
      let properties = read_v5_properties(
        reader,
        UnsubscribeProperties,
        direction,
        limits,
      )
      let topic_filters : Array[String] = []
      while reader.remaining() > 0 {
        if topic_filters.length() >= limits.max_subscription_entries {
          raise WireLimitExceeded(reader.position())
        }
        let topic_filter = reader.utf8()
        if !valid_topic_filter(topic_filter) {
          raise InvalidWireValue(reader.position())
        }
        topic_filters.push(topic_filter)
      }
      if topic_filters.length() == 0 {
        raise InvalidWireValue(reader.position())
      }
      Unsubscribe5({ packet_id, properties, topic_filters })
    }
    11 => {
      let packet_id = read_packet_id(reader)
      let properties = read_v5_properties(
        reader,
        UnsubackProperties,
        direction,
        limits,
      )
      let reasons : Array[Int] = []
      while reader.remaining() > 0 {
        let reason = reader.u8()
        if !reason_allowed(UnsubackReason, direction, reason) {
          raise InvalidWireValue(reader.position())
        }
        reasons.push(reason)
      }
      if reasons.length() == 0 {
        raise InvalidWireValue(reader.position())
      }
      Unsuback5({ packet_id, properties, reasons })
    }
    12 => {
      reader.finish()
      Pingreq5
    }
    13 => {
      reader.finish()
      Pingresp5
    }
    14 => {
      let (reason, properties) = read_v5_disconnect_or_auth(
        reader,
        DisconnectProperties,
        DisconnectReason,
        direction,
        limits,
      )
      Disconnect5({ reason, properties })
    }
    15 => {
      let (reason, properties) = read_v5_disconnect_or_auth(
        reader,
        AuthProperties,
        AuthReason,
        direction,
        limits,
      )
      Auth5({ reason, properties })
    }
    _ => raise InvalidWireValue(0)
  }
}

///|
pub fn decode_v5(
  frame : Bytes,
  direction : PacketDirection,
  limits : DecodeLimits,
) -> Result[PacketV5, WireError] {
  try {
    if frame.length() < 2 || frame.length() > limits.max_packet_bytes {
      raise WireLimitExceeded(0)
    }
    let header = WireReader::new(frame)
    let first = header.u8()
    let kind = first >> 4
    let flags = first & 15
    let body_length = header.vbi()
    if body_length != header.remaining() {
      raise InvalidWireValue(header.position())
    }
    let body = WireReader::bounded(frame, header.position(), frame.length())
    Ok(decode_v5_body(kind, flags, body, direction, limits))
  } catch {
    error => Err(error)
  }
}
