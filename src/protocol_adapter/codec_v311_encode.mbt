///|
fn legacy_qos_bits(qos : QoS) -> Int {
  match qos {
    QoS0 => 0
    QoS1 => 1
    QoS2 => 2
  }
}

///|
fn legacy_code(code : ConnectReturnCode) -> Int {
  match code {
    Accepted => 0
    UnacceptableProtocolVersion => 1
    IdentifierRejected => 2
    ServerUnavailable => 3
    BadUsernameOrPassword => 4
    NotAuthorized => 5
  }
}

///|
fn legacy_suback_code(code : SubackReturnCode) -> Int {
  match code {
    GrantedQoS0 => 0
    GrantedQoS1 => 1
    GrantedQoS2 => 2
    Failure => 0x80
  }
}

///|
fn encode_v311_body(packet : Packet, body : WireWriter) -> Int raise WireError {
  match packet {
    Connect(connect) => {
      if connect.keep_alive < 0 ||
        connect.keep_alive > 65535 ||
        (connect.password is Some(_) && connect.username is None) {
        raise InvalidWireValue(0)
      }
      body.utf8("MQTT")
      body.u8(4)
      let mut flags = if connect.clean_session { 2 } else { 0 }
      if connect.username is Some(_) {
        flags = flags | 0x80
      }
      if connect.password is Some(_) {
        flags = flags | 0x40
      }
      if connect.will is Some(will) {
        flags = flags | 4 | (legacy_qos_bits(will.qos) << 3)
        if will.retain {
          flags = flags | 0x20
        }
      }
      body.u8(flags)
      body.u16(connect.keep_alive)
      body.utf8(connect.client_id)
      if connect.will is Some(will) {
        if !valid_topic_name(will.topic, false) {
          raise InvalidWireValue(0)
        }
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
    Connack(connack) => {
      let code = legacy_code(connack.return_code)
      if code != 0 && connack.session_present {
        raise InvalidWireValue(0)
      }
      body.u8(if connack.session_present { 1 } else { 0 })
      body.u8(code)
      0x20
    }
    Publish(publish) => {
      let qos = legacy_qos_bits(publish.qos)
      if (qos == 0 && publish.packet_id is Some(_)) ||
        (qos != 0 && publish.packet_id is None) {
        raise WireInvalidPacketId(0)
      }
      if qos == 0 && publish.dup {
        raise WireInvalidFlags(0)
      }
      if !valid_topic_name(publish.topic, false) {
        raise InvalidWireValue(0)
      }
      body.utf8(publish.topic)
      if publish.packet_id is Some(id) {
        body.u16(id.value())
      }
      body.raw(publish.payload)
      0x30 |
      (if publish.dup { 8 } else { 0 }) |
      (qos << 1) |
      (if publish.retain { 1 } else { 0 })
    }
    Puback(id) => {
      body.u16(id.value())
      0x40
    }
    Pubrec(id) => {
      body.u16(id.value())
      0x50
    }
    Pubrel(id) => {
      body.u16(id.value())
      0x62
    }
    Pubcomp(id) => {
      body.u16(id.value())
      0x70
    }
    Subscribe(subscribe) => {
      if subscribe.subscriptions.length() == 0 {
        raise InvalidWireValue(0)
      }
      body.u16(subscribe.packet_id.value())
      for entry in subscribe.subscriptions {
        if !valid_topic_filter(entry.topic_filter) {
          raise InvalidWireValue(0)
        }
        body.utf8(entry.topic_filter)
        body.u8(legacy_qos_bits(entry.requested_qos))
      }
      0x82
    }
    Suback(suback) => {
      if suback.return_codes.length() == 0 {
        raise InvalidWireValue(0)
      }
      body.u16(suback.packet_id.value())
      for code in suback.return_codes {
        body.u8(legacy_suback_code(code))
      }
      0x90
    }
    Unsubscribe(unsubscribe) => {
      if unsubscribe.topic_filters.length() == 0 {
        raise InvalidWireValue(0)
      }
      body.u16(unsubscribe.packet_id.value())
      for filter in unsubscribe.topic_filters {
        if !valid_topic_filter(filter) {
          raise InvalidWireValue(0)
        }
        body.utf8(filter)
      }
      0xa2
    }
    Unsuback(id) => {
      body.u16(id.value())
      0xb0
    }
    Pingreq => 0xc0
    Pingresp => 0xd0
    Disconnect => 0xe0
  }
}

///|
pub fn encode_v311(packet : Packet) -> Result[Bytes, CodecError] {
  let result : Result[Bytes, WireError] = try {
    let body = WireWriter::new(268435455)
    let first = encode_v311_body(packet, body)
    let frame = WireWriter::new(268435460)
    frame.u8(first)
    frame.vbi(body.length())
    frame.raw(body.finish())
    Ok(frame.finish())
  } catch {
    error => Err(error)
  }
  match result {
    Ok(bytes) => Ok(bytes)
    Err(error) => Err(legacy_codec_error(error))
  }
}
