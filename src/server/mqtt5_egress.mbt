///|
fn legacy_packet_to_v5(packet : @protocol.Packet) -> @protocol.PacketV5? {
  match packet {
    Connack(value) =>
      Some(
        Connack5({
          session_present: value.session_present,
          reason: mqtt5_rejection_reason(value.return_code),
          properties: [],
        }),
      )
    Publish(value) =>
      Some(
        Publish5({
          topic: value.topic,
          payload: value.payload,
          qos: value.qos,
          packet_id: value.packet_id,
          dup: value.dup,
          retain: value.retain,
          properties: [],
        }),
      )
    Puback(id) => Some(Puback5({ packet_id: id, reason: 0, properties: [] }))
    Pubrec(id) => Some(Pubrec5({ packet_id: id, reason: 0, properties: [] }))
    Pubrel(id) => Some(Pubrel5({ packet_id: id, reason: 0, properties: [] }))
    Pubcomp(id) => Some(Pubcomp5({ packet_id: id, reason: 0, properties: [] }))
    Suback(value) => {
      let reasons : Array[Int] = []
      for code in value.return_codes {
        reasons.push(
          match code {
            GrantedQoS0 => 0
            GrantedQoS1 => 1
            GrantedQoS2 => 2
            Failure => 0x80
          },
        )
      }
      Some(Suback5({ packet_id: value.packet_id, properties: [], reasons }))
    }
    Unsuback(id) =>
      Some(Unsuback5({ packet_id: id, properties: [], reasons: [0] }))
    Pingresp => Some(Pingresp5)
    _ => None
  }
}

///|
fn mqtt5_remaining_expiry_seconds(
  deadline : @session.Deadline,
  now_mono_ms : Int64,
) -> UInt {
  let remaining = deadline.remaining_at(now_mono_ms)
  let rounded = remaining / 1000L +
    (if remaining % 1000L == 0L { 0L } else { 1L })
  if rounded > 4294967295L {
    0xffffffffU
  } else {
    rounded.to_int().reinterpret_as_uint()
  }
}

///|
fn mqtt5_refresh_expiry_packet(
  packet : @protocol.PacketV5,
  deadline : @session.Deadline,
  now_mono_ms : Int64,
) -> @protocol.PacketV5 {
  match packet {
    Publish5(publish) => {
      let properties : Array[@protocol.Property] = []
      for property in publish.properties {
        if property.id == 0x02 {
          properties.push({
            id: 0x02,
            value: @protocol.FourByteValue(
              mqtt5_remaining_expiry_seconds(deadline, now_mono_ms),
            ),
          })
        } else {
          properties.push(property)
        }
      }
      Publish5({ ..publish, properties, })
    }
    _ => packet
  }
}

///|
fn mqtt5_message_properties(
  metadata : @session.MessageMetadata,
  now_mono_ms : Int64,
  subscription_identifiers? : Array[Int] = [],
) -> Array[@protocol.Property] {
  let properties : Array[@protocol.Property] = []
  if metadata.payload_format is Some(value) {
    properties.push({ id: 0x01, value: @protocol.ByteValue(value) })
  }
  if metadata.expiry is Some(deadline) {
    properties.push({
      id: 0x02,
      value: @protocol.FourByteValue(
        mqtt5_remaining_expiry_seconds(deadline, now_mono_ms),
      ),
    })
  }
  if metadata.content_type is Some(value) {
    properties.push({ id: 0x03, value: @protocol.StringValue(value) })
  }
  if metadata.response_topic is Some(value) {
    properties.push({ id: 0x08, value: @protocol.StringValue(value.value()) })
  }
  if metadata.correlation_data is Some(value) {
    properties.push({ id: 0x09, value: @protocol.BinaryValue(value) })
  }
  for id in subscription_identifiers {
    properties.push({ id: 0x0b, value: @protocol.VariableValue(id) })
  }
  for pair in metadata.user_properties {
    let (key, value) = pair
    properties.push({ id: 0x26, value: @protocol.StringPair(key, value) })
  }
  properties
}

///|
fn BrokerRuntime::handle_write_not_started(
  self : BrokerRuntime,
  event : WriteNotStartedEvent,
) -> Array[RuntimeAction] {
  if self.active_by_client.get(event.client_id) != Some(event.connection_id) ||
    self.broker_state.policy_session_incarnation(event.client_id) !=
    event.session_incarnation ||
    self.broker_state.inflight_delivery_id(
      event.client_id,
      @session.SessionPacketId::new(event.packet_id.value()).unwrap(),
    ) !=
    Some(event.delivery_id) {
    return []
  }
  let kind = if event.qos == @protocol.QoS2 {
    @session.V5Pubrec
  } else {
    @session.V5Puback
  }
  match
    self.broker_state.apply(
      @router.OutboundAckV5({
        client_id: event.client_id,
        packet_id: @session.SessionPacketId::new(event.packet_id.value()).unwrap(),
        kind,
        negative: event.qos == @protocol.QoS2,
      }),
    ) {
    Ok(actions) => {
      self.metrics.record_dropped()
      self.map_broker_actions(actions)
    }
    Err(_) => self.terminate(event.connection_id, ProtocolError)
  }
}
