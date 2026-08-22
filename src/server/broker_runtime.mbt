///|
pub struct BrokerRuntime {
  config : ServerConfig
  broker_state : @router.BrokerState
  connections : Map[ConnectionId, ConnectionMeta]
  active_by_client : Map[@session.ClientId, ConnectionId]
}

///|
pub fn BrokerRuntime::new(
  config : ServerConfig,
  initial_state : @router.BrokerState,
) -> BrokerRuntime {
  {
    config,
    broker_state: initial_state,
    connections: Map([]),
    active_by_client: Map([]),
  }
}

///|
pub fn BrokerRuntime::connection_count(self : BrokerRuntime) -> Int {
  self.connections.length()
}

///|
pub fn BrokerRuntime::has_connection(
  self : BrokerRuntime,
  connection_id : ConnectionId,
) -> Bool {
  self.connections.get(connection_id) is Some(_)
}

///|
pub fn BrokerRuntime::active_connection(
  self : BrokerRuntime,
  client_id : @session.ClientId,
) -> ConnectionId? {
  self.active_by_client.get(client_id)
}

///|
pub fn BrokerRuntime::broker_state(self : BrokerRuntime) -> @router.BrokerState {
  self.broker_state
}

///|
fn accepted_connack_packet() -> @protocol.Packet {
  Connack({ session_present: false, return_code: Accepted })
}

///|
fn rejected_connack_packet(
  code : @protocol.ConnectReturnCode,
) -> @protocol.Packet {
  Connack({ session_present: false, return_code: code })
}

///|
fn copy_runtime_bytes(payload : Bytes) -> Bytes {
  Bytes::from_array(payload.to_array())
}

///|
fn qos_from_protocol(qos : @protocol.QoS) -> @session.DeliveryQoS? {
  match qos {
    QoS0 => Some(@session.DeliveryQoS::QoS0)
    QoS1 => Some(@session.DeliveryQoS::QoS1)
    QoS2 => None
  }
}

///|
fn BrokerRuntime::reject_connect(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  code : @protocol.ConnectReturnCode,
) -> Array[RuntimeAction] {
  self.connections.remove(connection_id)
  [
    SendPacketThenClose({
      connection_id,
      packet: rejected_connack_packet(code),
      reason: ConnectRejected,
    }),
  ]
}

///|
fn BrokerRuntime::map_broker_actions(
  self : BrokerRuntime,
  broker_actions : Array[@router.BrokerAction],
) -> Array[RuntimeAction] {
  let actions : Array[RuntimeAction] = []
  for broker_action in broker_actions {
    match broker_action {
      Deliver(delivery) =>
        match self.active_by_client.get(delivery.recipient) {
          None => ()
          Some(connection_id) =>
            match delivery.qos {
              QoS0 =>
                actions.push(
                  SendPacket({
                    connection_id,
                    packet: Publish({
                      topic: delivery.topic.value(),
                      payload: copy_runtime_bytes(delivery.payload),
                      qos: @protocol.QoS::QoS0,
                      packet_id: None,
                      dup: false,
                      retain: delivery.retain,
                    }),
                  }),
                )
              QoS1 =>
                actions.append(self.terminate(connection_id, ProtocolError))
            }
        }
      _ => ()
    }
  }
  actions
}

///|
fn BrokerRuntime::publish(
  self : BrokerRuntime,
  input : @router.PublishInput,
) -> Result[Array[RuntimeAction], @router.RouterError] {
  match self.broker_state.apply(@router.BrokerEvent::Publish(input)) {
    Err(error) => Err(error)
    Ok(broker_actions) => Ok(self.map_broker_actions(broker_actions))
  }
}

///|
fn BrokerRuntime::terminate(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  reason : CloseReason,
) -> Array[RuntimeAction] {
  let meta = match self.connections.get(connection_id) {
    None => return []
    Some(meta) => meta
  }
  self.connections.remove(connection_id)
  let actions : Array[RuntimeAction] = []
  match meta.phase {
    AwaitConnect => ()
    Active(client_id) => {
      if self.active_by_client.get(client_id) == Some(connection_id) {
        self.active_by_client.remove(client_id)
        if self.broker_state.has_session(client_id) {
          ignore(
            self.broker_state.apply(
              @router.BrokerEvent::RemoveSession(client_id),
            ),
          )
        }
      }
      let publish_will = reason != NormalDisconnect &&
        reason != ConnectRejected &&
        reason != ServerShutdown
      if publish_will {
        match meta.will {
          None => ()
          Some(will) => {
            let input : @router.PublishInput = {
              origin: Will(client_id),
              topic: will.topic,
              payload: copy_runtime_bytes(will.payload),
              qos: @session.DeliveryQoS::QoS0,
              retain: will.retain,
            }
            match self.publish(input) {
              Ok(will_actions) => actions.append(will_actions)
              Err(@router.RouterError::RetainedLimitReached(_)) => {
                let degraded = { ..input, retain: false }
                match self.publish(degraded) {
                  Ok(will_actions) => actions.append(will_actions)
                  Err(_) => ()
                }
              }
              Err(_) => ()
            }
          }
        }
      }
    }
  }
  actions.push(CloseTransport({ connection_id, reason }))
  actions
}

///|
fn BrokerRuntime::handle_connect(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  packet : @protocol.ConnectPacket,
  received_at_ms : Int64,
) -> Array[RuntimeAction] {
  if !packet.clean_session {
    let code = if packet.client_id == "" {
      @protocol.ConnectReturnCode::IdentifierRejected
    } else {
      @protocol.ConnectReturnCode::ServerUnavailable
    }
    return self.reject_connect(connection_id, code)
  }
  let client_id_value = if packet.client_id == "" {
    "moonbit-auto-" + connection_id.value().to_string()
  } else {
    packet.client_id
  }
  let client_id = match @session.ClientId::new(client_id_value) {
    Err(_) => return self.reject_connect(connection_id, IdentifierRejected)
    Ok(value) => value
  }
  let stored_will = match packet.will {
    None => None
    Some(will) => {
      match will.qos {
        QoS1 => return self.reject_connect(connection_id, ServerUnavailable)
        QoS2 => return self.terminate(connection_id, ProtocolError)
        QoS0 => ()
      }
      let topic = match @topic.TopicName::new(will.topic) {
        Err(_) => return self.terminate(connection_id, ProtocolError)
        Ok(value) => value
      }
      Some({
        topic,
        payload: copy_runtime_bytes(will.payload),
        retain: will.retain,
      })
    }
  }
  let actions : Array[RuntimeAction] = []
  match self.active_by_client.get(client_id) {
    Some(old_connection_id) if old_connection_id != connection_id =>
      actions.append(self.terminate(old_connection_id, ClientTakeover))
    _ => ()
  }
  if self.broker_state.has_session(client_id) {
    ignore(
      self.broker_state.apply(@router.BrokerEvent::RemoveSession(client_id)),
    )
  }
  match self.broker_state.apply(@router.BrokerEvent::CreateSession(client_id)) {
    Err(_) => return self.terminate(connection_id, ProtocolError)
    Ok(_) => ()
  }
  self.active_by_client.set(client_id, connection_id)
  self.connections.set(connection_id, {
    id: connection_id,
    phase: Active(client_id),
    accepted_at_ms: received_at_ms,
    last_control_at_ms: received_at_ms,
    keep_alive_seconds: packet.keep_alive,
    will: stored_will,
  })
  actions.push(SendPacket({ connection_id, packet: accepted_connack_packet() }))
  actions
}

///|
fn BrokerRuntime::close_protocol_error(
  self : BrokerRuntime,
  connection_id : ConnectionId,
) -> Array[RuntimeAction] {
  self.terminate(connection_id, ProtocolError)
}

///|
fn BrokerRuntime::handle_subscribe(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  packet : @protocol.SubscribePacket,
) -> Array[RuntimeAction] {
  let entries : Array[@router.SubscribeEntry] = []
  for subscription in packet.subscriptions {
    let filter = match @topic.TopicFilter::new(subscription.topic_filter) {
      Err(_) => return self.close_protocol_error(connection_id)
      Ok(value) => value
    }
    let qos = match qos_from_protocol(subscription.requested_qos) {
      None => return self.close_protocol_error(connection_id)
      Some(value) => value
    }
    entries.push({ filter, qos })
  }
  let broker_actions = match
    self.broker_state.apply(
      @router.BrokerEvent::Subscribe({ client_id, entries }),
    ) {
    Err(_) => return self.close_protocol_error(connection_id)
    Ok(value) => value
  }
  let actions : Array[RuntimeAction] = []
  match broker_actions[0] {
    SubscriptionsApplied(applied) => {
      let return_codes : Array[@protocol.SubackReturnCode] = []
      for result in applied.results {
        match result {
          Granted(qos) =>
            return_codes.push(
              match qos {
                QoS0 => GrantedQoS0
                QoS1 => GrantedQoS1
              },
            )
          RejectedLimit(_) => return_codes.push(Failure)
        }
      }
      actions.push(
        SendPacket({
          connection_id,
          packet: Suback({ packet_id: packet.packet_id, return_codes }),
        }),
      )
    }
    _ => return self.close_protocol_error(connection_id)
  }
  actions.append(self.map_broker_actions(broker_actions))
  actions
}

///|
fn BrokerRuntime::handle_unsubscribe(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  packet : @protocol.UnsubscribePacket,
) -> Array[RuntimeAction] {
  let filters : Array[@topic.TopicFilter] = []
  for filter_value in packet.topic_filters {
    match @topic.TopicFilter::new(filter_value) {
      Err(_) => return self.close_protocol_error(connection_id)
      Ok(filter) => filters.push(filter)
    }
  }
  match
    self.broker_state.apply(
      @router.BrokerEvent::Unsubscribe({ client_id, filters }),
    ) {
    Err(_) => self.close_protocol_error(connection_id)
    Ok(_) => [SendPacket({ connection_id, packet: Unsuback(packet.packet_id) })]
  }
}

///|
fn BrokerRuntime::handle_active_packet(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  packet : @protocol.Packet,
) -> Array[RuntimeAction] {
  match packet {
    Pingreq => [SendPacket({ connection_id, packet: Pingresp })]
    Disconnect => self.terminate(connection_id, NormalDisconnect)
    Publish(publish_packet) => {
      let qos = match publish_packet.qos {
        QoS0 => @session.DeliveryQoS::QoS0
        _ => return self.close_protocol_error(connection_id)
      }
      let topic = match @topic.TopicName::new(publish_packet.topic) {
        Err(_) => return self.close_protocol_error(connection_id)
        Ok(value) => value
      }
      let result = self.publish({
        origin: Client(client_id),
        topic,
        payload: copy_runtime_bytes(publish_packet.payload),
        qos,
        retain: publish_packet.retain,
      })
      match result {
        Ok(actions) => actions
        Err(_) => self.close_protocol_error(connection_id)
      }
    }
    Subscribe(subscribe_packet) =>
      self.handle_subscribe(connection_id, client_id, subscribe_packet)
    Unsubscribe(unsubscribe_packet) =>
      self.handle_unsubscribe(connection_id, client_id, unsubscribe_packet)
    _ => self.close_protocol_error(connection_id)
  }
}

///|
fn BrokerRuntime::handle_packet(
  self : BrokerRuntime,
  event : PacketReceivedEvent,
) -> Array[RuntimeAction] {
  let meta = match self.connections.get(event.connection_id) {
    None => return []
    Some(value) => value
  }
  match meta.phase {
    AwaitConnect =>
      match event.packet {
        Connect(packet) =>
          self.handle_connect(event.connection_id, packet, event.received_at_ms)
        _ => self.close_protocol_error(event.connection_id)
      }
    Active(client_id) => {
      self.connections.set(event.connection_id, {
        ..meta,
        last_control_at_ms: event.received_at_ms,
      })
      self.handle_active_packet(event.connection_id, client_id, event.packet)
    }
  }
}

///|
fn BrokerRuntime::check_deadlines(
  self : BrokerRuntime,
  now_ms : Int64,
) -> Array[RuntimeAction] {
  let expired : Array[(ConnectionId, CloseReason)] = []
  for connection_id, meta in self.connections {
    match meta.phase {
      AwaitConnect =>
        if now_ms >=
          meta.accepted_at_ms + self.config.connect_timeout_ms().to_int64() {
          expired.push((connection_id, ConnectTimeout))
        }
      Active(_) =>
        if meta.keep_alive_seconds > 0 &&
          now_ms >=
          meta.last_control_at_ms + meta.keep_alive_seconds.to_int64() * 1500L {
          expired.push((connection_id, KeepAliveTimeout))
        }
    }
  }
  let actions : Array[RuntimeAction] = []
  for pair in expired {
    let (connection_id, reason) = pair
    actions.append(self.terminate(connection_id, reason))
  }
  actions
}

///|
pub fn BrokerRuntime::apply(
  self : BrokerRuntime,
  event : RuntimeEvent,
) -> Array[RuntimeAction] {
  match event {
    TransportOpened(opened) => {
      if self.connections.get(opened.connection_id) is Some(_) {
        return []
      }
      if self.connections.length() >= self.config.max_connections() {
        return [
          CloseTransport({
            connection_id: opened.connection_id,
            reason: ServerShutdown,
          }),
        ]
      }
      self.connections.set(opened.connection_id, {
        id: opened.connection_id,
        phase: AwaitConnect,
        accepted_at_ms: opened.accepted_at_ms,
        last_control_at_ms: opened.accepted_at_ms,
        keep_alive_seconds: 0,
        will: None,
      })
      []
    }
    PacketReceived(packet) => self.handle_packet(packet)
    TransportClosed(closed) =>
      self.terminate(closed.connection_id, closed.reason)
    CheckDeadlines(now_ms) => self.check_deadlines(now_ms)
  }
}

///|
pub fn BrokerRuntime::check_invariants(
  self : BrokerRuntime,
) -> Result[Unit, ServerError] {
  if self.connections.length() > self.config.max_connections() {
    return Err(RuntimeInvariantViolation("connection limit exceeded"))
  }
  match self.broker_state.check_invariants() {
    Err(_) =>
      return Err(RuntimeInvariantViolation("broker state is inconsistent"))
    Ok(_) => ()
  }
  for client_id, connection_id in self.active_by_client {
    match self.connections.get(connection_id) {
      Some({ phase: Active(bound_client), .. }) if bound_client == client_id =>
        ()
      _ =>
        return Err(
          RuntimeInvariantViolation("active client index is inconsistent"),
        )
    }
    if !self.broker_state.has_session(client_id) {
      return Err(RuntimeInvariantViolation("active client has no session"))
    }
  }
  for connection_id, meta in self.connections {
    if meta.id != connection_id {
      return Err(RuntimeInvariantViolation("connection id/key mismatch"))
    }
    match meta.phase {
      AwaitConnect =>
        if meta.keep_alive_seconds != 0 || meta.will is Some(_) {
          return Err(
            RuntimeInvariantViolation("await-connect metadata is active"),
          )
        }
      Active(client_id) => {
        if self.active_by_client.get(client_id) != Some(connection_id) {
          return Err(
            RuntimeInvariantViolation("connection index is inconsistent"),
          )
        }
        if !self.broker_state.has_session(client_id) {
          return Err(
            RuntimeInvariantViolation("active connection has no session"),
          )
        }
      }
    }
  }
  Ok(())
}
