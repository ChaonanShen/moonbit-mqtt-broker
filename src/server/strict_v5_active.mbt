///|
pub fn BrokerRuntime::prepare_strict_v5_active_packet(
  self : BrokerRuntime,
  event : Mqtt5PacketReceivedEvent,
  generations : Map[@session.ClientId, Int64],
) -> StrictPacketPlan {
  let meta = match self.connections.get(event.connection_id) {
    Some(value) => value
    None => return StrictImmediate([])
  }
  let client_id = match meta.phase {
    Active(value) if self.active_by_client.get(value) ==
      Some(event.connection_id) &&
      self.v5_active.contains(event.connection_id) => value
    _ => return StrictClose(event.connection_id, ProtocolError)
  }
  if event.rx_error is Some(reason) {
    return StrictImmediate([
      SendMqtt5({
        expiry_deadline: None,
        rx_permit: None,
        connection_id: event.connection_id,
        packet: Disconnect5({ reason, properties: [] }),
        close_reason: Some(ProtocolError),
      }),
    ])
  }
  if !self.connection_credential_current(event.connection_id) {
    return StrictClose(event.connection_id, PolicyRevoked)
  }
  self.connections.set(event.connection_id, {
    ..meta,
    last_control_at_ms: event.received_at_ms,
  })
  match event.packet {
    Pingreq5 =>
      StrictImmediate([
        SendMqtt5({
          expiry_deadline: None,
          rx_permit: None,
          connection_id: event.connection_id,
          packet: Pingresp5,
          close_reason: None,
        }),
      ])
    Publish5(packet) =>
      self.prepare_strict_v5_publish(
        event.connection_id,
        client_id,
        meta.principal.unwrap(),
        packet,
        event.rx_permit,
        generations,
      )
    Subscribe5(packet) =>
      self.prepare_strict_v5_subscribe(
        event.connection_id,
        client_id,
        meta.principal.unwrap(),
        packet,
        generations,
      )
    Unsubscribe5(packet) =>
      self.prepare_strict_v5_unsubscribe(
        event.connection_id,
        client_id,
        packet,
        generations,
      )
    Puback5(packet) | Pubrec5(packet) | Pubcomp5(packet) =>
      self.prepare_strict_v5_outbound_ack(
        event.connection_id,
        client_id,
        event.packet,
        packet,
        generations,
      )
    Pubrel5(packet) =>
      self.prepare_strict_v5_pubrel(
        event.connection_id,
        client_id,
        packet,
        generations,
      )
    Disconnect5(packet) =>
      self.prepare_strict_v5_disconnect(
        event.connection_id,
        event.received_at_ms,
        packet,
        generations,
      )
    _ =>
      match mqtt5_legacy_input(event.packet) {
        Some(legacy) =>
          self.prepare_strict_active_packet(
            {
              connection_id: event.connection_id,
              packet: legacy,
              received_at_ms: event.received_at_ms,
            },
            generations,
          )
        None =>
          StrictImmediate([
            SendMqtt5({
              expiry_deadline: None,
              rx_permit: None,
              connection_id: event.connection_id,
              packet: Disconnect5({ reason: 0x83, properties: [] }),
              close_reason: Some(ProtocolError),
            }),
          ])
      }
  }
}

///|
fn BrokerRuntime::prepare_strict_v5_publish(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  principal : @security.Principal,
  packet : @protocol.PublishV5,
  rx_permit : RxPermit?,
  generations : Map[@session.ClientId, Int64],
) -> StrictPacketPlan {
  self.metrics.record_received()
  let packet_id = packet.packet_id.map(value => {
    @session.SessionPacketId::new(value.value()).unwrap()
  })
  let duplicate = packet.qos == @protocol.QoS2 &&
    packet_id is Some(value) &&
    self.broker_state.has_inbound_qos2(client_id, value)
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
      return StrictImmediate(
        self.mqtt5_publish_failure(
          connection_id,
          packet,
          error.reason,
          rx_permit,
        ),
      )
  }
  if duplicate {
    return StrictImmediate([
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
    ])
  }
  if !self.security.can_write_topic(principal, normalized.publish.topic) {
    self.metrics.record_acl_denial()
    self.metrics.record_dropped()
    return StrictImmediate(
      self.mqtt5_publish_failure(connection_id, packet, 0x87, rx_permit),
    )
  }
  if !self.admission.admit_publish(
      client_id,
      @budget.utf8_bytes(normalized.publish.topic.value()) +
      normalized.publish.payload.length().to_int64(),
    ) {
    return StrictImmediate(
      self.mqtt5_publish_failure(connection_id, packet, 0x97, rx_permit),
    )
  }
  let prepared = if packet.qos == @protocol.QoS2 {
    self.broker_state.prepare_durable_publish(
      normalized.publish,
      generations,
      inbound_packet_id=packet_id.unwrap(),
      metadata=normalized.metadata,
    )
  } else {
    self.broker_state.prepare_durable_publish(
      normalized.publish,
      generations,
      metadata=normalized.metadata,
    )
  }
  let plan = match prepared {
    Ok(value) => value
    Err(_) =>
      return StrictImmediate(
        self.mqtt5_publish_failure(connection_id, packet, 0x97, rx_permit),
      )
  }
  StrictPrepared(Publish(plan), broker_actions => {
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
  })
}

///|
fn BrokerRuntime::prepare_strict_v5_subscribe(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  principal : @security.Principal,
  packet : @protocol.SubscribeV5,
  generations : Map[@session.ClientId, Int64],
) -> StrictPacketPlan {
  if self.broker_state.has_inbound_qos2(
      client_id,
      @session.SessionPacketId::new(packet.packet_id.value()).unwrap(),
    ) {
    return StrictClose(connection_id, ProtocolError)
  }
  let mut subscription_id : Int? = None
  for property in packet.properties {
    if property.id == 0x0b && property.value is @protocol.VariableValue(value) {
      subscription_id = Some(value)
    }
  }
  let entries : Array[@router.SubscribeEntry] = []
  let entries_v5 : Array[@router.SubscribeEntryV5] = []
  let status : Array[Int] = []
  for item in packet.subscriptions {
    if item.no_local && item.topic_filter.has_prefix("$share/") {
      return StrictImmediate([
        SendMqtt5({
          expiry_deadline: None,
          rx_permit: None,
          connection_id,
          packet: Disconnect5({ reason: 0x82, properties: [] }),
          close_reason: Some(ProtocolError),
        }),
      ])
    }
    let filter = match @topic.TopicFilter::new(item.topic_filter) {
      Ok(value) => value
      Err(_) => return StrictClose(connection_id, ProtocolError)
    }
    if item.topic_filter.has_prefix("$share/") {
      status.push(0x9e)
    } else if !self.security.can_read_filter(principal, filter) {
      self.metrics.record_acl_denial()
      status.push(0x87)
    } else {
      let qos = qos_from_protocol(item.requested_qos).unwrap()
      entries.push({ filter, qos })
      entries_v5.push({
        filter,
        qos,
        no_local: item.no_local,
        retain_as_published: item.retain_as_published,
        retain_handling: item.retain_handling,
        subscription_identifier: subscription_id,
      })
      status.push(0)
    }
  }
  if entries.is_empty() {
    return StrictImmediate([
      SendMqtt5({
        expiry_deadline: None,
        rx_permit: None,
        connection_id,
        packet: Suback5({
          packet_id: packet.packet_id,
          properties: [],
          reasons: status,
        }),
        close_reason: None,
      }),
    ])
  }
  let generation = generations.get(client_id).unwrap_or(1L)
  let plan = match
    self.broker_state.prepare_durable_subscribe(
      client_id,
      entries,
      generation,
      v5_entries=entries_v5,
    ) {
    Ok(value) => value
    Err(_) =>
      return StrictImmediate([
        SendMqtt5({
          expiry_deadline: None,
          rx_permit: None,
          connection_id,
          packet: Suback5({
            packet_id: packet.packet_id,
            properties: [],
            reasons: status.map(value => if value == 0 { 0x97 } else { value }),
          }),
          close_reason: None,
        }),
      ])
  }
  StrictPrepared(PreparedBrokerMutation::Subscribe(plan), broker_actions => {
    let applied = match broker_actions[0] {
      @router.SubscriptionsApplied(value) => value.results
      _ => return []
    }
    let reasons : Array[Int] = []
    let mut index = 0
    for value in status {
      if value != 0 {
        reasons.push(value)
      } else {
        let code = match applied[index] {
          @router.Granted(qos) =>
            match qos {
              @session.QoS0 => 0
              @session.QoS1 => 1
              @session.QoS2 => 2
            }
          @router.RejectedLimit(_) => 0x97
          @router.RejectedSharedUnsupported => 0x9e
        }
        reasons.push(code)
        index += 1
      }
    }
    let actions : Array[RuntimeAction] = [
      SendMqtt5({
        expiry_deadline: None,
        rx_permit: None,
        connection_id,
        packet: Suback5({ packet_id: packet.packet_id, properties: [], reasons }),
        close_reason: None,
      }),
    ]
    actions.append(self.map_broker_actions(broker_actions))
    actions
  })
}

///|
fn BrokerRuntime::prepare_strict_v5_unsubscribe(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  packet : @protocol.UnsubscribeV5,
  generations : Map[@session.ClientId, Int64],
) -> StrictPacketPlan {
  let filters : Array[@topic.TopicFilter] = []
  for text in packet.topic_filters {
    let filter = match @topic.TopicFilter::new(text) {
      Ok(value) => value
      Err(_) => return StrictClose(connection_id, ProtocolError)
    }
    filters.push(filter)
  }
  let generation = generations.get(client_id).unwrap_or(1L)
  let plan = match
    self.broker_state.prepare_durable_unsubscribe(
      client_id, filters, generation,
    ) {
    Ok(value) => value
    Err(_) => return StrictClose(connection_id, ResourceExhausted)
  }
  StrictPrepared(Unsubscribe(plan), broker_actions => {
    let removed = match broker_actions[0] {
      @router.UnsubscriptionsApplied(value) => value.removed
      _ => return []
    }
    [
      SendMqtt5({
        expiry_deadline: None,
        rx_permit: None,
        connection_id,
        packet: Unsuback5({
          packet_id: packet.packet_id,
          properties: [],
          reasons: removed.map(value => if value { 0 } else { 0x11 }),
        }),
        close_reason: None,
      }),
    ]
  })
}

///|
fn BrokerRuntime::prepare_strict_v5_outbound_ack(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  wire : @protocol.PacketV5,
  packet : @protocol.AckV5,
  generations : Map[@session.ClientId, Int64],
) -> StrictPacketPlan {
  let kind = match wire {
    Puback5(_) => @router.V5OutboundPuback
    Pubrec5(_) =>
      if packet.reason >= 0x80 {
        @router.V5OutboundPubrecNegative
      } else {
        @router.V5OutboundPubrec
      }
    _ => @router.V5OutboundPubcomp
  }
  let generation = generations.get(client_id).unwrap_or(1L)
  let plan = match
    self.broker_state.prepare_durable_ack(
      client_id,
      @session.SessionPacketId::new(packet.packet_id.value()).unwrap(),
      kind,
      generation,
    ) {
    Ok(value) => value
    Err(_) =>
      return StrictImmediate([
        SendMqtt5({
          expiry_deadline: None,
          rx_permit: None,
          connection_id,
          packet: Disconnect5({ reason: 0x82, properties: [] }),
          close_reason: Some(ProtocolError),
        }),
      ])
  }
  StrictPrepared(Ack(plan), broker_actions => {
    self.map_broker_actions(broker_actions)
  })
}

///|
fn BrokerRuntime::prepare_strict_v5_pubrel(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  packet : @protocol.AckV5,
  generations : Map[@session.ClientId, Int64],
) -> StrictPacketPlan {
  let generation = generations.get(client_id).unwrap_or(1L)
  let plan = match
    self.broker_state.prepare_durable_ack(
      client_id,
      @session.SessionPacketId::new(packet.packet_id.value()).unwrap(),
      @router.V5InboundPubrel,
      generation,
    ) {
    Ok(value) => value
    Err(_) => return StrictClose(connection_id, ProtocolError)
  }
  StrictPrepared(Ack(plan), broker_actions => {
    self.map_broker_actions(broker_actions)
  })
}

///|
fn BrokerRuntime::prepare_strict_v5_disconnect(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  now_wall_ms : Int64,
  packet : @protocol.DisconnectV5,
  generations : Map[@session.ClientId, Int64],
) -> StrictPacketPlan {
  let initial = self.v5_active.get(connection_id).unwrap()
  let mut expiry_override : @session.Retention? = None
  for property in packet.properties {
    if property.id == 0x11 && property.value is @protocol.FourByteValue(seconds) {
      expiry_override = match
        @session.retention_from_disconnect(initial.retention, seconds) {
        Ok(value) => Some(value)
        Err(_) =>
          return StrictImmediate([
            SendMqtt5({
              expiry_deadline: None,
              rx_permit: None,
              connection_id,
              packet: Disconnect5({ reason: 0x82, properties: [] }),
              close_reason: Some(ProtocolError),
            }),
          ])
      }
    }
  }
  let closed : TransportClosedEvent = {
    connection_id,
    reason: if packet.reason == 4 {
      PeerEof
    } else {
      NormalDisconnect
    },
    observed_at_ms: now_wall_ms,
  }
  match expiry_override {
    Some(value) =>
      self.prepare_strict_termination(
        closed,
        generations,
        v5_retention_override=value,
      )
    None => self.prepare_strict_termination(closed, generations)
  }
}

///|
pub fn BrokerRuntime::prepare_strict_write_not_started(
  self : BrokerRuntime,
  event : WriteNotStartedEvent,
  generations : Map[@session.ClientId, Int64],
) -> StrictPacketPlan {
  if self.active_by_client.get(event.client_id) != Some(event.connection_id) ||
    self.broker_state.policy_session_incarnation(event.client_id) !=
    event.session_incarnation {
    return StrictImmediate([])
  }
  let kind = if event.qos == @protocol.QoS2 {
    @router.V5OutboundPubrecNegative
  } else {
    @router.V5OutboundPuback
  }
  let generation = generations.get(event.client_id).unwrap_or(1L)
  let plan = match
    self.broker_state.prepare_durable_ack(
      event.client_id,
      @session.SessionPacketId::new(event.packet_id.value()).unwrap(),
      kind,
      generation,
    ) {
    Ok(value) => value
    Err(_) => return StrictClose(event.connection_id, ProtocolError)
  }
  StrictPrepared(Ack(plan), actions => self.map_broker_actions(actions))
}
