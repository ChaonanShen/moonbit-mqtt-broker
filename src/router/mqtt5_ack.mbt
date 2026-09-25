///|
fn BrokerState::apply_v5_outbound_ack(
  self : BrokerState,
  request : OutboundAckV5Request,
) -> Result[Array[BrokerAction], RouterError] {
  let session = match self.sessions.get(request.client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(request.client_id))
  }
  let transition = match
    session.apply_v5_outbound_ack(
      request.packet_id,
      request.kind,
      request.negative,
    ) {
    Ok(value) => value
    Err(error) => return Err(SessionFailure(error))
  }
  let response : DeliveryAcknowledgedAction = {
    client_id: request.client_id,
    packet_id: request.packet_id,
  }
  match transition {
    V5UnknownPacketId =>
      if request.kind == @session.V5Pubrec {
        Ok([SendPubrelNotFound(response)])
      } else {
        Ok([])
      }
    V5SendPubrel => {
      if session.mode() == @session.Persistent {
        self.mark_snapshot_dirty()
      }
      Ok([SendPubrel(response)])
    }
    V5Terminal => {
      self.inflight_total -= 1
      if session.mode() == @session.Persistent {
        self.mark_snapshot_dirty()
      }
      Ok([DeliveryAcknowledged(response)])
    }
  }
}

///|
fn BrokerState::complete_qos2_v5(
  self : BrokerState,
  request : PubackRequest,
) -> Result[Array[BrokerAction], RouterError] {
  let session = match self.sessions.get(request.client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(request.client_id))
  }
  let response : DeliveryAcknowledgedAction = {
    client_id: request.client_id,
    packet_id: request.packet_id,
  }
  if !session.has_inbound_qos2(request.packet_id) {
    return Ok([SendPubcompNotFound(response)])
  }
  ignore(session.complete_inbound_qos2(request.packet_id))
  self.inbound_qos2_total -= 1
  if session.mode() == @session.Persistent {
    self.mark_snapshot_dirty()
  }
  Ok([SendPubcomp(response)])
}
