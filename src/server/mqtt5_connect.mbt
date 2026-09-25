///|
pub(all) struct PreparedMqtt5Connect {
  client_id : String
  assigned_client_id : Bool
  username : String?
  password : Bytes?
  will : @protocol.WillV5?
  retention : @session.Retention
  resume_decision : @session.ResumeDecision
  keep_alive_seconds : Int
  peer_receive_maximum : Int
  peer_max_packet_bytes : Int
  peer_topic_alias_maximum : Int
  request_problem_information : Bool
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5ConnectError {
  reason : Int
} derive(Eq, Debug)

///|
pub fn normalize_mqtt5_connect(
  packet : @protocol.ConnectV5,
  config : ServerConfig,
  occupied : (String) -> Bool,
) -> Result[PreparedMqtt5Connect, Mqtt5ConnectError] {
  let checked : Result[Unit, @protocol.WireError] = try {
    @protocol.validate_properties(
      packet.properties,
      @protocol.ConnectProperties,
      @protocol.ClientToServer,
      config.protocol_config().max_user_properties + 27,
    )
    Ok(())
  } catch {
    error => Err(error)
  }
  if checked is Err(_) {
    return Err({ reason: 0x82 })
  }
  let mut expiry = 0U
  let mut receive_maximum = 65535
  let mut max_packet_bytes = 268435460
  let mut alias_maximum = 0
  let mut problem_info = true
  for property in packet.properties {
    match (property.id, property.value) {
      (0x11, @protocol.FourByteValue(value)) => expiry = value
      (0x21, @protocol.TwoByteValue(value)) => receive_maximum = value
      (0x27, @protocol.FourByteValue(value)) =>
        max_packet_bytes = if value > 268435460U {
          268435460
        } else {
          value.reinterpret_as_int()
        }
      (0x22, @protocol.TwoByteValue(value)) => alias_maximum = value
      (0x17, @protocol.ByteValue(value)) => problem_info = value == 1
      (0x15, @protocol.StringValue(_)) => return Err({ reason: 0x8c })
      _ => ()
    }
  }
  if packet.will is Some(will) {
    if config.protocol_config().max_delayed_wills == 0 {
      return Err({ reason: 0x97 })
    }
    let checked_will : Result[Unit, @protocol.WireError] = try {
      @protocol.validate_properties(
        will.properties,
        @protocol.WillProperties,
        @protocol.ClientToServer,
        config.protocol_config().max_user_properties + 27,
      )
      Ok(())
    } catch {
      error => Err(error)
    }
    if checked_will is Err(_) {
      return Err({ reason: 0x82 })
    }
    for property in will.properties {
      if property.id == 0x01 && property.value == @protocol.ByteValue(1) {
        let text = @utf8.decode(will.payload) catch {
          _ => return Err({ reason: 0x99 })
        }
        ignore(text)
      }
    }
    if @topic.TopicName::new(will.topic) is Err(_) {
      return Err({ reason: 0x82 })
    }
  }
  let (client_id, assigned_client_id) = if packet.client_id == "" {
    match mqtt5_assign_id(occupied) {
      Some(value) => (value, true)
      None => return Err({ reason: 0x88 })
    }
  } else {
    (packet.client_id, false)
  }
  if @session.ClientId::new(client_id) is Err(_) {
    return Err({ reason: 0x85 })
  }
  Ok({
    client_id,
    assigned_client_id,
    username: packet.username,
    password: packet.password,
    will: packet.will,
    retention: @session.retention_from_connect(expiry),
    resume_decision: @session.resume_from_clean_start(packet.clean_start),
    keep_alive_seconds: if config.protocol_config().server_keep_alive >= 0 {
      config.protocol_config().server_keep_alive
    } else {
      packet.keep_alive
    },
    peer_receive_maximum: receive_maximum,
    peer_max_packet_bytes: max_packet_bytes,
    peer_topic_alias_maximum: alias_maximum,
    request_problem_information: problem_info,
  })
}

///|
pub fn mqtt5_connack(
  plan : PreparedMqtt5Connect,
  config : ServerConfig,
  session_present : Bool,
) -> @protocol.PacketV5 {
  let protocol = config.protocol_config()
  let properties : Array[@protocol.Property] = [
    { id: 0x21, value: @protocol.TwoByteValue(protocol.server_receive_maximum) },
    { id: 0x22, value: @protocol.TwoByteValue(protocol.topic_alias_maximum) },
    { id: 0x25, value: @protocol.ByteValue(1) },
    {
      id: 0x27,
      value: @protocol.FourByteValue(
        (if config.max_packet_size() > 268435460 {
          268435460
        } else {
          config.max_packet_size()
        }).reinterpret_as_uint(),
      ),
    },
    { id: 0x28, value: @protocol.ByteValue(1) },
    { id: 0x29, value: @protocol.ByteValue(1) },
    { id: 0x2a, value: @protocol.ByteValue(0) },
  ]
  if plan.assigned_client_id {
    properties.push({ id: 0x12, value: @protocol.StringValue(plan.client_id) })
  }
  if protocol.server_keep_alive >= 0 {
    properties.push({
      id: 0x13,
      value: @protocol.TwoByteValue(protocol.server_keep_alive),
    })
  }
  @protocol.Connack5({ session_present, reason: 0, properties })
}
