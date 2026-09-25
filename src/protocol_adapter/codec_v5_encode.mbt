///|
fn write_packet_id(writer : WireWriter, id : PacketId) -> Unit raise WireError {
  writer.u16(id.value())
}

///|
fn qos_bits(qos : QoS) -> Int {
  match qos {
    QoS0 => 0
    QoS1 => 1
    QoS2 => 2
  }
}

///|
fn write_v5_ack(
  body : WireWriter,
  packet : AckV5,
  location : PropertyLocation,
  reason_kind : ReasonPacketKind,
  direction : PacketDirection,
) -> Unit raise WireError {
  if !reason_allowed(reason_kind, direction, packet.reason) {
    raise InvalidWireValue(0)
  }
  write_packet_id(body, packet.packet_id)
  if packet.reason != 0 || packet.properties.length() != 0 {
    body.u8(packet.reason)
    if packet.properties.length() != 0 {
      encode_properties(body, packet.properties, location, direction)
    }
  }
}

///|
fn write_v5_disconnect_or_auth(
  body : WireWriter,
  reason : Int,
  properties : Array[Property],
  location : PropertyLocation,
  reason_kind : ReasonPacketKind,
  direction : PacketDirection,
) -> Unit raise WireError {
  if !reason_allowed(reason_kind, direction, reason) {
    raise InvalidWireValue(0)
  }
  if reason != 0 || properties.length() != 0 {
    body.u8(reason)
    if properties.length() != 0 {
      encode_properties(body, properties, location, direction)
    }
  }
}

///|
fn encode_v5_body(
  packet : PacketV5,
  body : WireWriter,
  direction : PacketDirection,
) -> Int raise WireError {
  match packet {
    Connect5(connect) => {
      if direction != ClientToServer ||
        connect.keep_alive < 0 ||
        connect.keep_alive > 65535 {
        raise InvalidWireValue(0)
      }
      body.utf8("MQTT")
      body.u8(5)
      let mut flags = if connect.clean_start { 2 } else { 0 }
      if connect.username is Some(_) {
        flags = flags | 0x80
      }
      if connect.password is Some(_) {
        flags = flags | 0x40
      }
      if connect.will is Some(will) {
        flags = flags | 4 | (qos_bits(will.qos) << 3)
        if will.retain {
          flags = flags | 0x20
        }
      }
      body.u8(flags)
      body.u16(connect.keep_alive)
      encode_properties(body, connect.properties, ConnectProperties, direction)
      body.utf8(connect.client_id)
      if connect.will is Some(will) {
        if !valid_topic_name(will.topic, false) {
          raise InvalidWireValue(0)
        }
        encode_properties(body, will.properties, WillProperties, direction)
        body.utf8(will.topic)
        body.binary16(will.payload)
      }
      if connect.username is Some(username) {
        body.utf8(username)
      }
      if connect.password is Some(password) {
        body.binary16(password)
      }
      0x10
    }
    Connack5(connack) => {
      if direction != ServerToClient ||
        !reason_allowed(ConnackReason, direction, connack.reason) ||
        (connack.reason != 0 && connack.session_present) {
        raise InvalidWireValue(0)
      }
      body.u8(if connack.session_present { 1 } else { 0 })
      body.u8(connack.reason)
      encode_properties(body, connack.properties, ConnackProperties, direction)
      0x20
    }
    Publish5(publish) => {
      let qos = qos_bits(publish.qos)
      if (publish.qos == QoS0 && (publish.dup || publish.packet_id is Some(_))) ||
        (publish.qos != QoS0 && publish.packet_id is None) {
        raise InvalidWireValue(0)
      }
      if !valid_topic_name(publish.topic, true) {
        raise InvalidWireValue(0)
      }
      body.utf8(publish.topic)
      if publish.packet_id is Some(id) {
        write_packet_id(body, id)
      }
      encode_properties(body, publish.properties, PublishProperties, direction)
      body.raw(publish.payload)
      0x30 |
      (if publish.dup { 8 } else { 0 }) |
      (qos << 1) |
      (if publish.retain { 1 } else { 0 })
    }
    Puback5(ack) => {
      write_v5_ack(body, ack, PubackProperties, PubackReason, direction)
      0x40
    }
    Pubrec5(ack) => {
      write_v5_ack(body, ack, PubrecProperties, PubrecReason, direction)
      0x50
    }
    Pubrel5(ack) => {
      write_v5_ack(body, ack, PubrelProperties, PubrelReason, direction)
      0x62
    }
    Pubcomp5(ack) => {
      write_v5_ack(body, ack, PubcompProperties, PubcompReason, direction)
      0x70
    }
    Subscribe5(subscribe) => {
      if direction != ClientToServer || subscribe.subscriptions.length() == 0 {
        raise InvalidWireValue(0)
      }
      write_packet_id(body, subscribe.packet_id)
      encode_properties(
        body,
        subscribe.properties,
        SubscribeProperties,
        direction,
      )
      for entry in subscribe.subscriptions {
        if !valid_topic_filter(entry.topic_filter) ||
          entry.retain_handling < 0 ||
          entry.retain_handling > 2 {
          raise InvalidWireValue(0)
        }
        body.utf8(entry.topic_filter)
        let options = qos_bits(entry.requested_qos) |
          (if entry.no_local { 4 } else { 0 }) |
          (if entry.retain_as_published { 8 } else { 0 }) |
          (entry.retain_handling << 4)
        body.u8(options)
      }
      0x82
    }
    Suback5(suback) => {
      if direction != ServerToClient || suback.reasons.length() == 0 {
        raise InvalidWireValue(0)
      }
      write_packet_id(body, suback.packet_id)
      encode_properties(body, suback.properties, SubackProperties, direction)
      for reason in suback.reasons {
        if !reason_allowed(SubackReason, direction, reason) {
          raise InvalidWireValue(0)
        }
        body.u8(reason)
      }
      0x90
    }
    Unsubscribe5(unsubscribe) => {
      if direction != ClientToServer || unsubscribe.topic_filters.length() == 0 {
        raise InvalidWireValue(0)
      }
      write_packet_id(body, unsubscribe.packet_id)
      encode_properties(
        body,
        unsubscribe.properties,
        UnsubscribeProperties,
        direction,
      )
      for topic_filter in unsubscribe.topic_filters {
        if !valid_topic_filter(topic_filter) {
          raise InvalidWireValue(0)
        }
        body.utf8(topic_filter)
      }
      0xa2
    }
    Unsuback5(unsuback) => {
      if direction != ServerToClient || unsuback.reasons.length() == 0 {
        raise InvalidWireValue(0)
      }
      write_packet_id(body, unsuback.packet_id)
      encode_properties(
        body,
        unsuback.properties,
        UnsubackProperties,
        direction,
      )
      for reason in unsuback.reasons {
        if !reason_allowed(UnsubackReason, direction, reason) {
          raise InvalidWireValue(0)
        }
        body.u8(reason)
      }
      0xb0
    }
    Pingreq5 => {
      if direction != ClientToServer {
        raise InvalidWireValue(0)
      }
      0xc0
    }
    Pingresp5 => {
      if direction != ServerToClient {
        raise InvalidWireValue(0)
      }
      0xd0
    }
    Disconnect5(disconnect) => {
      write_v5_disconnect_or_auth(
        body,
        disconnect.reason,
        disconnect.properties,
        DisconnectProperties,
        DisconnectReason,
        direction,
      )
      0xe0
    }
    Auth5(auth) => {
      write_v5_disconnect_or_auth(
        body,
        auth.reason,
        auth.properties,
        AuthProperties,
        AuthReason,
        direction,
      )
      0xf0
    }
  }
}

///|
pub fn encode_v5(
  packet : PacketV5,
  direction : PacketDirection,
  max_bytes : Int,
) -> Result[Bytes, WireError] {
  try {
    let body = WireWriter::new(max_bytes)
    let header = encode_v5_body(packet, body, direction)
    if body.length() > 268435455 {
      raise WireLimitExceeded(body.length())
    }
    let result = WireWriter::new(max_bytes)
    result.u8(header)
    result.vbi(body.length())
    result.raw(body.finish())
    Ok(result.finish())
  } catch {
    error => Err(error)
  }
}
