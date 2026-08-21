///|
fn classify_candidate_error(message : String) -> CodecError {
  if message.contains("trailing") {
    TrailingBytes(message)
  } else if message.contains("remaining length: malformed sequence") {
    InvalidRemainingLength(message)
  } else if message.contains("flag") || message.contains("DUP") {
    InvalidFlags(message)
  } else if message.contains("protocol name") {
    InvalidProtocolName(message)
  } else if message.contains("protocol level") {
    InvalidProtocolLevel(message)
  } else if message.contains("UTF-8") || message.contains("U+0000") {
    InvalidUtf8(message)
  } else if message.contains("packet identifier") {
    InvalidPacketId(message)
  } else if message.contains("QoS") || message.contains("qos") {
    UnsupportedQoS(message)
  } else if message.contains("message type") {
    UnsupportedPacketType(message)
  } else if message.contains("truncated") ||
    message.contains("length") ||
    message.contains("body") ||
    message.contains("empty") ||
    message.contains("return code") ||
    message.contains("wildcard") {
    InvalidPacketShape(message)
  } else {
    BackendFailure(message)
  }
}

///|
fn validate_canonical_frame(frame : Bytes) -> Result[Unit, CodecError] {
  if frame.length() < 2 {
    return Err(InvalidPacketShape("fixed header is truncated"))
  }
  let packet_type = (frame[0].to_int() >> 4) & 0x0f
  if packet_type == 0 || packet_type == 15 {
    return Err(UnsupportedPacketType("reserved MQTT control packet type"))
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
fn qos_from_candidate(qos : @candidate.QoS) -> Result[QoS, CodecError] {
  match qos {
    @candidate.QoS::QoS0 => Ok(QoS0)
    @candidate.QoS::QoS1 => Ok(QoS1)
    @candidate.QoS::QoS2 => Err(UnsupportedQoS("QoS 2 is not supported"))
  }
}

///|
fn qos_to_candidate(qos : QoS) -> Result[@candidate.QoS, CodecError] {
  match qos {
    QoS0 => Ok(@candidate.QoS::QoS0)
    QoS1 => Ok(@candidate.QoS::QoS1)
    QoS2 => Err(UnsupportedQoS("QoS 2 is not supported"))
  }
}

///|
fn packet_id_from_candidate(value : Int) -> Result[PacketId, CodecError] {
  PacketId::new(value)
}

///|
fn connect_code_from_candidate(
  code : @candidate.ConnackReturnCode,
) -> ConnectReturnCode {
  match code {
    @candidate.ConnackReturnCode::ConnectionAccepted => Accepted
    @candidate.ConnackReturnCode::UnacceptableProtocolVersion =>
      UnacceptableProtocolVersion
    @candidate.ConnackReturnCode::IdentifierRejected => IdentifierRejected
    @candidate.ConnackReturnCode::ServerUnavailable => ServerUnavailable
    @candidate.ConnackReturnCode::BadUserNameOrPassword => BadUsernameOrPassword
    @candidate.ConnackReturnCode::NotAuthorized => NotAuthorized
  }
}

///|
fn connect_code_to_candidate(
  code : ConnectReturnCode,
) -> @candidate.ConnackReturnCode {
  match code {
    Accepted => @candidate.ConnackReturnCode::ConnectionAccepted
    UnacceptableProtocolVersion =>
      @candidate.ConnackReturnCode::UnacceptableProtocolVersion
    IdentifierRejected => @candidate.ConnackReturnCode::IdentifierRejected
    ServerUnavailable => @candidate.ConnackReturnCode::ServerUnavailable
    BadUsernameOrPassword => @candidate.ConnackReturnCode::BadUserNameOrPassword
    NotAuthorized => @candidate.ConnackReturnCode::NotAuthorized
  }
}

///|
fn suback_code_from_candidate(
  code : @candidate.SubackReturnCode,
) -> Result[SubackReturnCode, CodecError] {
  match code {
    @candidate.SubackReturnCode::SuccessQoS0 => Ok(GrantedQoS0)
    @candidate.SubackReturnCode::SuccessQoS1 => Ok(GrantedQoS1)
    @candidate.SubackReturnCode::SuccessQoS2 =>
      Err(UnsupportedQoS("QoS 2 is not supported"))
    @candidate.SubackReturnCode::Failure => Ok(Failure)
  }
}

///|
fn suback_code_to_candidate(
  code : SubackReturnCode,
) -> Result[@candidate.SubackReturnCode, CodecError] {
  match code {
    GrantedQoS0 => Ok(@candidate.SubackReturnCode::SuccessQoS0)
    GrantedQoS1 => Ok(@candidate.SubackReturnCode::SuccessQoS1)
    GrantedQoS2 => Err(UnsupportedQoS("QoS 2 is not supported"))
    Failure => Ok(@candidate.SubackReturnCode::Failure)
  }
}

///|
fn candidate_decode_packet(frame : Bytes) -> Result[Packet, CodecError] {
  match validate_canonical_frame(frame) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let decoded = match @candidate.decode_packet(frame.to_array()) {
    Ok(packet) => packet
    Err(message) => return Err(classify_candidate_error(message))
  }
  match decoded {
    @candidate.Packet::ConnectPacket(connect) => {
      if connect.flags.password && !connect.flags.username {
        return Err(InvalidFlags("CONNECT password flag requires username flag"))
      }
      let will = if connect.flags.will_flag {
        let qos = match qos_from_candidate(connect.flags.will_qos) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        Some({
          topic: connect.will_topic.unwrap(),
          payload: connect.will_message.unwrap(),
          qos,
          retain: connect.flags.will_retain,
        })
      } else {
        None
      }
      Ok(
        Connect({
          client_id: connect.client_id,
          username: connect.username,
          password: connect.password,
          keep_alive: connect.keep_alive,
          clean_session: connect.flags.clean_session,
          will,
        }),
      )
    }
    @candidate.Packet::ConnackPacket(connack) =>
      Ok(
        Connack({
          session_present: connack.session_present,
          return_code: connect_code_from_candidate(connack.return_code),
        }),
      )
    @candidate.Packet::PublishPacket(publish) => {
      let qos = match qos_from_candidate(publish.qos) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let packet_id = match publish.message_id {
        Some(value) =>
          match packet_id_from_candidate(value) {
            Ok(id) => Some(id)
            Err(error) => return Err(error)
          }
        None => None
      }
      Ok(
        Publish({
          topic: publish.topic,
          payload: publish.payload,
          qos,
          packet_id,
          dup: publish.dup,
          retain: publish.retain,
        }),
      )
    }
    @candidate.Packet::PubackPacket(id) =>
      packet_id_from_candidate(id.message_id).map(packet_id => Puback(packet_id))
    @candidate.Packet::SubscribePacket(subscribe) => {
      let id = match packet_id_from_candidate(subscribe.message_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let subscriptions = []
      for topic in subscribe.topics {
        let qos = match qos_from_candidate(topic.qos) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        subscriptions.push({ topic_filter: topic.topic, requested_qos: qos })
      }
      Ok(Subscribe({ packet_id: id, subscriptions }))
    }
    @candidate.Packet::SubackPacket(suback) => {
      let id = match packet_id_from_candidate(suback.message_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let return_codes = []
      for code in suback.return_codes {
        match suback_code_from_candidate(code) {
          Ok(value) => return_codes.push(value)
          Err(error) => return Err(error)
        }
      }
      Ok(Suback({ packet_id: id, return_codes }))
    }
    @candidate.Packet::UnsubscribePacket(unsubscribe) =>
      match packet_id_from_candidate(unsubscribe.message_id) {
        Ok(id) =>
          Ok(Unsubscribe({ packet_id: id, topic_filters: unsubscribe.topics }))
        Err(error) => Err(error)
      }
    @candidate.Packet::UnsubackPacket(unsuback) =>
      packet_id_from_candidate(unsuback.message_id).map(packet_id => {
        Unsuback(packet_id)
      })
    @candidate.Packet::PingreqPacket => Ok(Pingreq)
    @candidate.Packet::PingrespPacket => Ok(Pingresp)
    @candidate.Packet::DisconnectPacket => Ok(Disconnect)
    @candidate.Packet::PubrecPacket(_)
    | @candidate.Packet::PubrelPacket(_)
    | @candidate.Packet::PubcompPacket(_) =>
      Err(UnsupportedPacketType("QoS 2 control packet is not supported"))
  }
}

///|
fn candidate_encode_packet(packet : Packet) -> Result[Bytes, CodecError] {
  let candidate_packet : @candidate.Packet = match packet {
    Connect(connect) => {
      if connect.password is Some(_) && connect.username is None {
        return Err(InvalidFlags("CONNECT password requires username"))
      }
      let will_qos = match connect.will {
        Some(will) =>
          match qos_to_candidate(will.qos) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
        None => @candidate.QoS::QoS0
      }
      @candidate.Packet::ConnectPacket({
        client_id: connect.client_id,
        username: connect.username,
        password: connect.password,
        will_topic: connect.will.map(will => will.topic),
        will_message: connect.will.map(will => will.payload),
        keep_alive: connect.keep_alive,
        flags: {
          username: connect.username is Some(_),
          password: connect.password is Some(_),
          will_retain: connect.will.map(will => will.retain).unwrap_or(false),
          will_qos,
          will_flag: connect.will is Some(_),
          clean_session: connect.clean_session,
        },
      })
    }
    Connack(connack) =>
      @candidate.Packet::ConnackPacket({
        session_present: connack.session_present,
        return_code: connect_code_to_candidate(connack.return_code),
      })
    Publish(publish) => {
      let qos = match qos_to_candidate(publish.qos) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      @candidate.Packet::PublishPacket({
        topic: publish.topic,
        payload: publish.payload,
        qos,
        message_id: publish.packet_id.map(id => id.value()),
        retain: publish.retain,
        dup: publish.dup,
      })
    }
    Puback(id) => @candidate.Packet::PubackPacket({ message_id: id.value() })
    Subscribe(subscribe) => {
      let topics : Array[@candidate.SubscribeTopic] = []
      for subscription in subscribe.subscriptions {
        let qos = match qos_to_candidate(subscription.requested_qos) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        topics.push({ topic: subscription.topic_filter, qos })
      }
      @candidate.Packet::SubscribePacket({
        topics,
        message_id: subscribe.packet_id.value(),
      })
    }
    Suback(suback) => {
      let return_codes = []
      for code in suback.return_codes {
        match suback_code_to_candidate(code) {
          Ok(value) => return_codes.push(value)
          Err(error) => return Err(error)
        }
      }
      @candidate.Packet::SubackPacket({
        message_id: suback.packet_id.value(),
        return_codes,
      })
    }
    Unsubscribe(unsubscribe) =>
      @candidate.Packet::UnsubscribePacket({
        topics: unsubscribe.topic_filters,
        message_id: unsubscribe.packet_id.value(),
      })
    Unsuback(id) =>
      @candidate.Packet::UnsubackPacket({ message_id: id.value() })
    Pingreq => @candidate.Packet::PingreqPacket
    Pingresp => @candidate.Packet::PingrespPacket
    Disconnect => @candidate.Packet::DisconnectPacket
  }
  match @candidate.encode_packet(candidate_packet) {
    Ok(bytes) => Ok(Bytes::from_array(bytes))
    Err(message) => Err(classify_candidate_error(message))
  }
}
