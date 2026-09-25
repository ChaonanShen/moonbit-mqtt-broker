///|
fn BrokerRuntime::handle_mqtt5_packet(
  self : BrokerRuntime,
  event : Mqtt5PacketReceivedEvent,
) -> Array[RuntimeAction] {
  let meta = match self.connections.get(event.connection_id) {
    Some(value) => value
    None => return []
  }
  match (meta.phase, event.packet) {
    (AwaitConnect, Connect5(_)) => {
      self.connections.remove(event.connection_id)
      [
        SendMqtt5({
          connection_id: event.connection_id,
          packet: Connack5({
            session_present: false,
            reason: if self.config.protocol_config().mqtt5_enabled {
              0x83
            } else {
              0x84
            },
            properties: [],
          }),
          close_reason: Some(ConnectRejected),
        }),
      ]
    }
    _ => self.terminate(event.connection_id, ProtocolError)
  }
}
