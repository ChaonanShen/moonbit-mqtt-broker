///|
fn mqtt5_rejection_reason(code : @protocol.ConnectReturnCode) -> Int {
  match code {
    Accepted => 0
    UnacceptableProtocolVersion => 0x84
    IdentifierRejected => 0x85
    ServerUnavailable => 0x88
    BadUsernameOrPassword => 0x86
    NotAuthorized => 0x87
  }
}

///|
fn BrokerRuntime::reject_mqtt5_connect(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  reason : Int,
) -> Array[RuntimeAction] {
  self.v5_pending.remove(connection_id)
  self.connections.remove(connection_id)
  [
    SendMqtt5({
      connection_id,
      packet: Connack5({ session_present: false, reason, properties: [] }),
      close_reason: Some(ConnectRejected),
    }),
  ]
}

///|
fn mqtt5_legacy_input(packet : @protocol.PacketV5) -> @protocol.Packet? {
  match packet {
    Publish5(value) if value.properties.is_empty() =>
      Some(
        Publish({
          topic: value.topic,
          payload: value.payload,
          qos: value.qos,
          packet_id: value.packet_id,
          dup: value.dup,
          retain: value.retain,
        }),
      )
    Subscribe5(value) if value.properties.is_empty() => {
      let subscriptions : Array[@protocol.Subscription] = []
      for item in value.subscriptions {
        if item.no_local ||
          item.retain_as_published ||
          item.retain_handling != 0 ||
          item.topic_filter.has_prefix("$share/") {
          return None
        }
        subscriptions.push({
          topic_filter: item.topic_filter,
          requested_qos: item.requested_qos,
        })
      }
      Some(Subscribe({ packet_id: value.packet_id, subscriptions }))
    }
    Unsubscribe5(value) if value.properties.is_empty() =>
      Some(
        Unsubscribe({
          packet_id: value.packet_id,
          topic_filters: value.topic_filters,
        }),
      )
    Puback5(value) if value.reason == 0 && value.properties.is_empty() =>
      Some(Puback(value.packet_id))
    Pubrec5(value) if value.reason == 0 && value.properties.is_empty() =>
      Some(Pubrec(value.packet_id))
    Pubrel5(value) if value.reason == 0 && value.properties.is_empty() =>
      Some(Pubrel(value.packet_id))
    Pubcomp5(value) if value.reason == 0 && value.properties.is_empty() =>
      Some(Pubcomp(value.packet_id))
    _ => None
  }
}

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
    (AwaitConnect, Connect5(connect)) => {
      if !self.config.protocol_config().mqtt5_enabled {
        return self.reject_mqtt5_connect(event.connection_id, 0x84)
      }
      let plan = match
        normalize_mqtt5_connect(connect, self.config, client_id => {
          self.broker_state.has_session(
            @session.ClientId::new(client_id).unwrap(),
          )
        }) {
        Ok(value) => value
        Err(error) =>
          return self.reject_mqtt5_connect(event.connection_id, error.reason)
      }
      // The first runtime activation stage keeps unsupported state out of V3 storage.
      if plan.will is Some(_) || plan.retention != @session.DropOnClose {
        return self.reject_mqtt5_connect(event.connection_id, 0x83)
      }
      self.v5_pending.set(event.connection_id, {
        ..plan,
        username: None,
        password: None,
      })
      let legacy : @protocol.ConnectPacket = {
        client_id: plan.client_id,
        username: connect.username,
        password: connect.password,
        keep_alive: plan.keep_alive_seconds,
        clean_session: plan.resume_decision == @session.StartFresh,
        will: None,
      }
      self.handle_connect(event.connection_id, legacy, event.received_at_ms)
    }
    (Active(client_id), packet) if self.v5_active.contains(event.connection_id) &&
      mqtt5_legacy_input(packet) is Some(legacy) => {
      if self.active_by_client.get(client_id) != Some(event.connection_id) {
        return []
      }
      if !self.connection_credential_current(event.connection_id) {
        return self.terminate(event.connection_id, PolicyRevoked)
      }
      let current = self.connections.get(event.connection_id).unwrap()
      self.connections.set(event.connection_id, {
        ..current,
        last_control_at_ms: event.received_at_ms,
      })
      self.handle_active_packet(
        event.connection_id,
        client_id,
        current.principal.unwrap(),
        legacy,
      )
    }
    (Active(_), Pingreq5) if self.v5_active.contains(event.connection_id) => {
      self.connections.set(event.connection_id, {
        ..meta,
        last_control_at_ms: event.received_at_ms,
      })
      [
        SendMqtt5({
          connection_id: event.connection_id,
          packet: Pingresp5,
          close_reason: None,
        }),
      ]
    }
    (Active(_), Disconnect5(disconnect)) if self.v5_active.contains(
        event.connection_id,
      ) =>
      if disconnect.reason == 0 {
        self.terminate(event.connection_id, NormalDisconnect)
      } else {
        self.terminate(event.connection_id, PeerEof)
      }
    _ => self.terminate(event.connection_id, ProtocolError)
  }
}
