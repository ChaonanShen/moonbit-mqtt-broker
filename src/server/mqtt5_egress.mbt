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
    let remaining = deadline.remaining_at(now_mono_ms)
    let rounded = remaining / 1000L +
      (if remaining % 1000L == 0L { 0L } else { 1L })
    let seconds = if rounded > 4294967295L {
      0xffffffffU
    } else {
      rounded.to_int().reinterpret_as_uint()
    }
    properties.push({ id: 0x02, value: @protocol.FourByteValue(seconds) })
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
