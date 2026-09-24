///|
pub enum StrictPacketPlan {
  StrictImmediate(Array[RuntimeAction])
  StrictClose(ConnectionId, CloseReason)
  StrictPrepared(
    PreparedBrokerMutation,
    (Array[@router.BrokerAction]) -> Array[RuntimeAction]
  )
}

///|
fn BrokerRuntime::strict_packet_id(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  packet : @protocol.PublishPacket,
) -> Result[@protocol.PacketId?, CloseReason] {
  ignore(self)
  ignore(connection_id)
  match packet.qos {
    QoS0 =>
      if packet.packet_id is Some(_) || packet.dup {
        Err(ProtocolError)
      } else {
        Ok(None)
      }
    QoS1 | QoS2 =>
      match packet.packet_id {
        Some(value) => Ok(Some(value))
        None => Err(ProtocolError)
      }
  }
}

///|
pub fn BrokerRuntime::prepare_strict_active_packet(
  self : BrokerRuntime,
  event : PacketReceivedEvent,
  generations : Map[@session.ClientId, Int64],
) -> StrictPacketPlan {
  let meta = match self.connections.get(event.connection_id) {
    Some(value) => value
    None => return StrictImmediate([])
  }
  let client_id = match meta.phase {
    Active(value) if self.active_by_client.get(value) ==
      Some(event.connection_id) => value
    _ => return StrictClose(event.connection_id, ProtocolError)
  }
  if !self.connection_credential_current(event.connection_id) {
    return StrictClose(event.connection_id, PolicyRevoked)
  }
  let current = self.connections.get(event.connection_id).unwrap()
  self.connections.set(event.connection_id, {
    ..current,
    last_control_at_ms: event.received_at_ms,
  })
  let principal = current.principal.unwrap()
  match event.packet {
    Pingreq =>
      StrictImmediate([
        SendPacket({ connection_id: event.connection_id, packet: Pingresp }),
      ])
    Publish(packet) => {
      self.metrics.record_received()
      let incoming_id = match
        self.strict_packet_id(event.connection_id, packet) {
        Ok(value) => value
        Err(reason) => return StrictClose(event.connection_id, reason)
      }
      let topic = match @topic.TopicName::new(packet.topic) {
        Ok(value) => value
        Err(_) => return StrictClose(event.connection_id, ProtocolError)
      }
      let qos = qos_from_protocol(packet.qos).unwrap()
      let session_id = incoming_id.map(value => {
        @session.SessionPacketId::new(value.value()).unwrap()
      })
      if packet.qos == @protocol.QoS::QoS2 {
        let packet_id = session_id.unwrap()
        let committed_duplicate = self.broker_state.has_inbound_qos2(
          client_id, packet_id,
        )
        if committed_duplicate {
          self.metrics.record_qos2(duplicate=true)
          return StrictPrepared(Noop, _ => {
            [
              SendPacket({
                connection_id: event.connection_id,
                packet: Pubrec(incoming_id.unwrap()),
              }),
            ]
          })
        }
        if !self.security.can_write_topic(principal, topic) {
          self.metrics.record_acl_denial()
          self.metrics.record_dropped()
          let generation = generations.get(client_id).unwrap_or(1L)
          let plan = match
            self.broker_state.prepare_durable_ack(
              client_id,
              packet_id,
              InboundPublishDropped,
              generation,
            ) {
            Ok(value) => value
            Err(_) => return StrictClose(event.connection_id, ResourceExhausted)
          }
          return StrictPrepared(Ack(plan), broker_actions => {
            self.map_broker_actions(broker_actions)
          })
        }
        if !self.admission.admit_publish(
            client_id,
            @budget.utf8_bytes(packet.topic) +
            packet.payload.length().to_int64(),
          ) {
          return StrictClose(event.connection_id, RateLimited)
        }
        let input : @router.PublishInput = {
          origin: Client(client_id),
          topic,
          payload: copy_runtime_bytes(packet.payload),
          qos,
          retain: packet.retain,
        }
        let plan = match
          self.broker_state.prepare_durable_publish(
            input,
            generations,
            inbound_packet_id=packet_id,
          ) {
          Ok(value) => value
          Err(_) => {
            self.metrics.record_qos2_rejection()
            return StrictClose(event.connection_id, ResourceExhausted)
          }
        }
        self.metrics.record_qos2(duplicate=false)
        return StrictPrepared(PreparedBrokerMutation::Publish(plan), broker_actions => {
          self.map_broker_actions(broker_actions)
        })
      }
      if session_id is Some(packet_id) &&
        self.broker_state.has_inbound_qos2(client_id, packet_id) {
        return StrictClose(event.connection_id, ProtocolError)
      }
      if !self.security.can_write_topic(principal, topic) {
        self.metrics.record_acl_denial()
        self.metrics.record_dropped()
        let actions : Array[RuntimeAction] = match incoming_id {
          Some(packet_id) =>
            [
              SendPacket({
                connection_id: event.connection_id,
                packet: Puback(packet_id),
              }),
            ]
          None => []
        }
        return StrictPrepared(Noop, _ => actions)
      }
      if !self.admission.admit_publish(
          client_id,
          @budget.utf8_bytes(packet.topic) + packet.payload.length().to_int64(),
        ) {
        return StrictClose(event.connection_id, RateLimited)
      }
      let input : @router.PublishInput = {
        origin: Client(client_id),
        topic,
        payload: copy_runtime_bytes(packet.payload),
        qos,
        retain: packet.retain,
      }
      let plan = match
        self.broker_state.prepare_durable_publish(input, generations) {
        Ok(value) => value
        Err(_) => return StrictClose(event.connection_id, ResourceExhausted)
      }
      StrictPrepared(PreparedBrokerMutation::Publish(plan), broker_actions => {
        let actions : Array[RuntimeAction] = []
        if incoming_id is Some(packet_id) {
          actions.push(
            SendPacket({
              connection_id: event.connection_id,
              packet: Puback(packet_id),
            }),
          )
        }
        actions.append(self.map_broker_actions(broker_actions))
        actions
      })
    }
    Puback(packet_id)
    | Pubrec(packet_id)
    | Pubrel(packet_id)
    | Pubcomp(packet_id) => {
      let request_id = @session.SessionPacketId::new(packet_id.value()).unwrap()
      let kind = match event.packet {
        Puback(_) => @router.DurableAckKind::OutboundPuback
        Pubrec(_) => @router.DurableAckKind::OutboundPubrec
        Pubrel(_) => @router.DurableAckKind::InboundPubrel
        _ => @router.DurableAckKind::OutboundPubcomp
      }
      let generation = generations.get(client_id).unwrap_or(1L)
      let plan = match
        self.broker_state.prepare_durable_ack(
          client_id, request_id, kind, generation,
        ) {
        Ok(value) => value
        Err(_) => return StrictClose(event.connection_id, ProtocolError)
      }
      StrictPrepared(Ack(plan), broker_actions => {
        self.map_broker_actions(broker_actions)
      })
    }
    Subscribe(packet) => {
      let entries : Array[@router.SubscribeEntry] = []
      let authorized : Array[Bool] = []
      for subscription in packet.subscriptions {
        let filter = match @topic.TopicFilter::new(subscription.topic_filter) {
          Ok(value) => value
          Err(_) => return StrictClose(event.connection_id, ProtocolError)
        }
        let qos = match qos_from_protocol(subscription.requested_qos) {
          Some(value) => value
          None => return StrictClose(event.connection_id, ProtocolError)
        }
        let allowed = self.security.can_read_filter(principal, filter)
        if !allowed {
          self.metrics.record_acl_denial()
        }
        authorized.push(allowed)
        if allowed {
          entries.push({ filter, qos })
        }
      }
      if entries.is_empty() {
        return StrictPrepared(Noop, _ => {
          [
            SendPacket({
              connection_id: event.connection_id,
              packet: Suback({
                packet_id: packet.packet_id,
                return_codes: authorized.map(_ => Failure),
              }),
            }),
          ]
        })
      }
      let generation = generations.get(client_id).unwrap_or(1L)
      let plan = match
        self.broker_state.prepare_durable_subscribe(
          client_id, entries, generation,
        ) {
        Ok(value) => value
        Err(_) => return StrictClose(event.connection_id, ResourceExhausted)
      }
      StrictPrepared(PreparedBrokerMutation::Subscribe(plan), broker_actions => {
        let return_codes : Array[@protocol.SubackReturnCode] = []
        let mut result_index = 0
        let granted = match broker_actions[0] {
          @router.SubscriptionsApplied(value) => value.results
          _ => return []
        }
        for allowed in authorized {
          if !allowed {
            return_codes.push(Failure)
          } else {
            match granted[result_index] {
              @router.Granted(qos) =>
                return_codes.push(
                  match qos {
                    @session.QoS0 => GrantedQoS0
                    @session.QoS1 => GrantedQoS1
                    @session.QoS2 => GrantedQoS2
                  },
                )
              @router.RejectedLimit(_) => return_codes.push(Failure)
            }
            result_index += 1
          }
        }
        let actions : Array[RuntimeAction] = [
          SendPacket({
            connection_id: event.connection_id,
            packet: Suback({ packet_id: packet.packet_id, return_codes }),
          }),
        ]
        actions.append(self.map_broker_actions(broker_actions))
        actions
      })
    }
    Unsubscribe(packet) => {
      let filters : Array[@topic.TopicFilter] = []
      for value in packet.topic_filters {
        match @topic.TopicFilter::new(value) {
          Ok(filter) => filters.push(filter)
          Err(_) => return StrictClose(event.connection_id, ProtocolError)
        }
      }
      let generation = generations.get(client_id).unwrap_or(1L)
      let plan = match
        self.broker_state.prepare_durable_unsubscribe(
          client_id, filters, generation,
        ) {
        Ok(value) => value
        Err(_) => return StrictClose(event.connection_id, ProtocolError)
      }
      StrictPrepared(Unsubscribe(plan), broker_actions => {
        let actions : Array[RuntimeAction] = [
          SendPacket({
            connection_id: event.connection_id,
            packet: Unsuback(packet.packet_id),
          }),
        ]
        actions.append(self.map_broker_actions(broker_actions))
        actions
      })
    }
    Disconnect => {
      let kind = match self.broker_state.session_mode(client_id) {
        Some(@session.Persistent) =>
          @router.DurableLifecycleKind::DetachAt(event.received_at_ms)
        Some(@session.Clean) => @router.DurableLifecycleKind::Delete
        None => return StrictClose(event.connection_id, ProtocolError)
      }
      let generation = generations.get(client_id).unwrap_or(1L)
      let plan = match
        self.broker_state.prepare_durable_lifecycle(client_id, generation, kind) {
        Ok(value) => value
        Err(_) => return StrictClose(event.connection_id, ResourceExhausted)
      }
      StrictPrepared(Lifecycle(plan), _ => {
        self.active_by_client.remove(client_id)
        self.connections.remove(event.connection_id)
        let will_ticket = self.will_tickets.get(event.connection_id)
        self.will_tickets.remove(event.connection_id)
        release_optional(will_ticket)
        [
          CloseTransport({
            connection_id: event.connection_id,
            reason: NormalDisconnect,
          }),
        ]
      })
    }
    _ => StrictClose(event.connection_id, ProtocolError)
  }
}
