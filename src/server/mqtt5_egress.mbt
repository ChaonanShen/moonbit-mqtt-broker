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
