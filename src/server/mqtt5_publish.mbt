///|
pub(all) struct Mqtt5PublishError {
  reason : Int
} derive(Eq, Debug)

///|
pub fn BrokerRuntime::normalize_mqtt5_publish(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  packet : @protocol.PublishV5,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  skip_payload_check? : Bool = false,
) -> Result[@router.PublishInputV5, Mqtt5PublishError] {
  let mut topic_alias : Int? = None
  for property in packet.properties {
    if property.id == 0x23 && property.value is @protocol.TwoByteValue(value) {
      topic_alias = Some(value)
    }
  }
  let table = match self.inbound_aliases.get(connection_id) {
    Some(value) => value
    None => return Err({ reason: 0x82 })
  }
  let topic_value = match topic_alias {
    Some(number) => {
      if number < 1 ||
        number > self.config.protocol_config().topic_alias_maximum {
        return Err({ reason: 0x94 })
      }
      if packet.topic == "" {
        match table.get(number) {
          Some(value) => value
          None => return Err({ reason: 0x94 })
        }
      } else {
        if @topic.TopicName::new(packet.topic) is Err(_) {
          return Err({ reason: 0x82 })
        }
        let mut used = 0L
        for _, value in table {
          used += 64L + @budget.utf8_bytes(value)
        }
        let previous = table.get(number)
        let adjusted = used -
          previous.map(value => 64L + @budget.utf8_bytes(value)).unwrap_or(0L) +
          64L +
          @budget.utf8_bytes(packet.topic)
        if adjusted +
          self.outbound_alias_bytes.get(connection_id).unwrap_or(0).to_int64() >
          self.config.protocol_config().max_alias_bytes_per_connection.to_int64() {
          return Err({ reason: 0x97 })
        }
        table.set(number, packet.topic)
        packet.topic
      }
    }
    None => packet.topic
  }
  let topic = match @topic.TopicName::new(topic_value) {
    Ok(value) => value
    Err(_) => return Err({ reason: 0x82 })
  }
  let mut payload_format : Int? = None
  let mut content_type : String? = None
  let mut response_topic : @topic.TopicName? = None
  let mut correlation_data : Bytes? = None
  let user_properties : Array[(String, String)] = []
  let mut expiry : @session.Deadline? = None
  for property in packet.properties {
    match (property.id, property.value) {
      (0x01, @protocol.ByteValue(value)) => payload_format = Some(value)
      (0x02, @protocol.FourByteValue(seconds)) =>
        match
          @session.Deadline::from_seconds(now_mono_ms, now_wall_ms, seconds) {
          Ok(value) => expiry = Some(value)
          Err(_) => return Err({ reason: 0x97 })
        }
      (0x03, @protocol.StringValue(value)) => content_type = Some(value)
      (0x08, @protocol.StringValue(value)) =>
        match @topic.TopicName::new(value) {
          Ok(topic) => response_topic = Some(topic)
          Err(_) => return Err({ reason: 0x82 })
        }
      (0x09, @protocol.BinaryValue(value)) => correlation_data = Some(value)
      (0x26, @protocol.StringPair(key, value)) =>
        user_properties.push((key, value))
      _ => ()
    }
  }
  if payload_format == Some(1) && !skip_payload_check {
    ignore(@utf8.decode(packet.payload)) catch {
      _ => return Err({ reason: 0x99 })
    }
  }
  let metadata : @session.MessageMetadata = {
    payload_format,
    content_type,
    response_topic,
    correlation_data,
    user_properties,
    publisher_client_id: Some(client_id),
    expiry,
  }
  Ok({
    publish: {
      origin: @router.PublishOrigin::Client(client_id),
      topic,
      payload: packet.payload,
      qos: match packet.qos {
        QoS0 => @session.QoS0
        QoS1 => @session.QoS1
        QoS2 => @session.QoS2
      },
      retain: packet.retain,
    },
    metadata,
  })
}

///|
fn BrokerRuntime::mqtt5_publish_failure(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  packet : @protocol.PublishV5,
  reason : Int,
  rx_permit : RxPermit?,
) -> Array[RuntimeAction] {
  if packet.qos == @protocol.QoS0 || reason == 0x82 || reason == 0x94 {
    return [
      SendMqtt5({
        expiry_deadline: None,
        rx_permit: None,
        connection_id,
        packet: Disconnect5({ reason, properties: [] }),
        close_reason: Some(ProtocolError),
      }),
    ]
  }
  let packet_id = match packet.packet_id {
    Some(value) => value
    None => return self.terminate(connection_id, ProtocolError)
  }
  let reply = if packet.qos == @protocol.QoS2 {
    @protocol.Pubrec5({ packet_id, reason, properties: [] })
  } else {
    @protocol.Puback5({ packet_id, reason, properties: [] })
  }
  [
    SendMqtt5({
      expiry_deadline: None,
      rx_permit,
      connection_id,
      packet: reply,
      close_reason: None,
    }),
  ]
}

///|
fn BrokerRuntime::handle_v5_publish(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  principal : @security.Principal,
  packet : @protocol.PublishV5,
  rx_permit : RxPermit?,
) -> Array[RuntimeAction] {
  self.metrics.record_received()
  let duplicate = packet.qos == @protocol.QoS2 &&
    packet.packet_id is Some(id) &&
    self.broker_state.has_inbound_qos2(
      client_id,
      @session.SessionPacketId::new(id.value()).unwrap(),
    )
  let normalized = match
    self.normalize_mqtt5_publish(
      connection_id,
      client_id,
      packet,
      @budget.monotonic_ms(),
      @async.now(),
      skip_payload_check=duplicate,
    ) {
    Ok(value) => value
    Err(error) =>
      return self.mqtt5_publish_failure(
        connection_id,
        packet,
        error.reason,
        rx_permit,
      )
  }
  if duplicate {
    return [
      SendMqtt5({
        expiry_deadline: None,
        rx_permit: None,
        connection_id,
        packet: Pubrec5({
          packet_id: packet.packet_id.unwrap(),
          reason: 0,
          properties: [],
        }),
        close_reason: None,
      }),
    ]
  }
  if !self.security.can_write_topic(principal, normalized.publish.topic) {
    self.metrics.record_acl_denial()
    self.metrics.record_dropped()
    return self.mqtt5_publish_failure(connection_id, packet, 0x87, rx_permit)
  }
  if !self.admission.admit_publish(
      client_id,
      @budget.utf8_bytes(normalized.publish.topic.value()) +
      normalized.publish.payload.length().to_int64(),
    ) {
    return self.mqtt5_publish_failure(connection_id, packet, 0x97, rx_permit)
  }
  let result = if packet.qos == @protocol.QoS2 {
    self.broker_state.apply(
      @router.ReceiveQoS2V5({
        client_id,
        packet_id: @session.SessionPacketId::new(
          packet.packet_id.unwrap().value(),
        ).unwrap(),
        publish: Some(normalized),
      }),
    )
  } else {
    self.broker_state.apply(@router.PublishV5(normalized))
  }
  match result {
    Ok(broker_actions) => {
      let actions = self.map_broker_actions(broker_actions)
      if packet.qos == @protocol.QoS1 {
        actions.push(
          SendMqtt5({
            expiry_deadline: None,
            rx_permit,
            connection_id,
            packet: Puback5({
              packet_id: packet.packet_id.unwrap(),
              reason: 0,
              properties: [],
            }),
            close_reason: None,
          }),
        )
      }
      actions
    }
    Err(@router.ByteResourceLimit(_))
    | Err(@router.QoS1ResourceLimit(_, _))
    | Err(@router.InboundQoS2ResourceLimit(_))
    | Err(@router.RetainedLimitReached(_)) =>
      self.mqtt5_publish_failure(connection_id, packet, 0x97, rx_permit)
    Err(_) => self.mqtt5_publish_failure(connection_id, packet, 0x83, rx_permit)
  }
}
