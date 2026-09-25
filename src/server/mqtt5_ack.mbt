///|
fn BrokerRuntime::handle_v5_outbound_ack(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  packet : @protocol.PacketV5,
) -> Array[RuntimeAction] {
  let (packet_id, kind, reason) = match packet {
    Puback5(value) => (value.packet_id, @session.V5Puback, value.reason)
    Pubrec5(value) => (value.packet_id, @session.V5Pubrec, value.reason)
    Pubcomp5(value) => (value.packet_id, @session.V5Pubcomp, value.reason)
    _ => return self.terminate(connection_id, ProtocolError)
  }
  let request : @router.OutboundAckV5Request = {
    client_id,
    packet_id: @session.SessionPacketId::new(packet_id.value()).unwrap(),
    kind,
    negative: reason >= 0x80,
  }
  match self.broker_state.apply(@router.OutboundAckV5(request)) {
    Ok(actions) => self.map_broker_actions(actions)
    Err(@router.SessionFailure(@session.InvalidAcknowledgement)) =>
      [
        SendMqtt5({
          rx_permit: None,
          connection_id,
          packet: Disconnect5({ reason: 0x82, properties: [] }),
          close_reason: Some(ProtocolError),
        }),
      ]
    Err(_) => self.terminate(connection_id, ProtocolError)
  }
}

///|
fn BrokerRuntime::handle_v5_pubrel(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  packet : @protocol.AckV5,
) -> Array[RuntimeAction] {
  let request : @router.PubackRequest = {
    client_id,
    packet_id: @session.SessionPacketId::new(packet.packet_id.value()).unwrap(),
  }
  match self.broker_state.apply(@router.InboundPubrelV5(request)) {
    Ok(actions) => self.map_broker_actions(actions)
    Err(_) => self.terminate(connection_id, ProtocolError)
  }
}
