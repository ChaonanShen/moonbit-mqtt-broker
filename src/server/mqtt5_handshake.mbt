///|
fn RouterDriver::prepare_mqtt5_handshake(
  self : RouterDriver,
  event : Mqtt5PacketReceivedEvent,
) -> Bool {
  let connect = match event.packet {
    @protocol.Connect5(value) => value
    _ => return true
  }
  if !(self.runtime.connections.get(event.connection_id)
    is Some({ phase: AwaitConnect, .. })) {
    return true
  }
  let sink = match self.sinks.get(event.connection_id) {
    Some(value) => value
    None => return false
  }
  if sink.handshake is Some(_) {
    return true
  }
  let control_limit = self.runtime.config
    .broker_config()
    .resources()
    .get("control_reserve_bytes")
  if event.rx_error is Some(_) ||
    !self.runtime.config.protocol_config().mqtt5_enabled {
    if !sink.prepare_handshake(control_limit, frame_bytes=5L, scratch_bytes=10L) {
      self.dispatch(
        self.transport_failed(event.connection_id, ResourceExhausted),
      )
      return false
    }
    return true
  }
  let plan = match self.runtime.v5_pending.get(event.connection_id) {
    Some(value) => Some(value)
    None =>
      match
        normalize_mqtt5_connect(connect, self.runtime.config, client_id => {
          self.runtime
          .broker_state()
          .has_session(@session.ClientId::new(client_id).unwrap())
        }) {
        Ok(value) => Some(value)
        Err(_) => None
      }
  }
  let frame = match plan {
    None => None
    Some(value) =>
      match
        @protocol.encode_v5(
          mqtt5_connack(value, self.runtime.config, false),
          @protocol.ServerToClient,
          value.peer_max_packet_bytes,
        ) {
        Ok(value) => Some(value)
        Err(_) => None
      }
  }
  if plan is Some(value) && frame is None {
    if value.peer_max_packet_bytes < 5 {
      self.dispatch(self.transport_failed(event.connection_id, EncodeFailure))
      return false
    }
    self.runtime.v5_pending.set(event.connection_id, {
      ..value,
      username: None,
      password: None,
    })
    if !sink.prepare_handshake(control_limit, frame_bytes=5L, scratch_bytes=10L) {
      self.dispatch(
        self.transport_failed(event.connection_id, ResourceExhausted),
      )
    } else {
      self.dispatch(
        self.runtime.reject_connect(event.connection_id, ServerUnavailable),
      )
    }
    return false
  }
  let frame_bytes = frame.map(value => value.length().to_int64()).unwrap_or(5L)
  if !sink.prepare_handshake(
      control_limit,
      frame_bytes~,
      scratch_bytes=frame_bytes * 2L,
    ) {
    self.dispatch(self.transport_failed(event.connection_id, ResourceExhausted))
    return false
  }
  if plan is Some(value) {
    self.runtime.v5_pending.set(event.connection_id, {
      ..value,
      username: None,
      password: None,
    })
  }
  true
}
