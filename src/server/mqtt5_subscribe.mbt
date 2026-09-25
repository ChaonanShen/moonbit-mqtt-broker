///|
fn BrokerRuntime::handle_v5_subscribe(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  principal : @security.Principal,
  packet : @protocol.SubscribeV5,
) -> Array[RuntimeAction] {
  if self.broker_state.has_inbound_qos2(
      client_id,
      @session.SessionPacketId::new(packet.packet_id.value()).unwrap(),
    ) {
    return self.terminate(connection_id, ProtocolError)
  }
  let mut subscription_id : Int? = None
  for property in packet.properties {
    if property.id == 0x0b && property.value is @protocol.VariableValue(value) {
      subscription_id = Some(value)
    }
  }
  let entries : Array[@router.SubscribeEntryV5] = []
  let authorized : Array[Bool] = []
  for subscription in packet.subscriptions {
    if subscription.no_local && subscription.topic_filter.has_prefix("$share/") {
      return [
        SendMqtt5({
          connection_id,
          packet: Disconnect5({ reason: 0x82, properties: [] }),
          close_reason: Some(ProtocolError),
        }),
      ]
    }
    let filter = match @topic.TopicFilter::new(subscription.topic_filter) {
      Ok(value) => value
      Err(_) => return self.terminate(connection_id, ProtocolError)
    }
    let allowed = self.security.can_read_filter(principal, filter)
    if !allowed {
      self.metrics.record_acl_denial()
    }
    authorized.push(allowed)
    if allowed {
      entries.push({
        filter,
        qos: qos_from_protocol(subscription.requested_qos).unwrap(),
        no_local: subscription.no_local,
        retain_as_published: subscription.retain_as_published,
        retain_handling: subscription.retain_handling,
        subscription_identifier: subscription_id,
      })
    }
  }
  let broker_actions = if entries.is_empty() {
    []
  } else {
    match self.broker_state.apply(@router.SubscribeV5({ client_id, entries })) {
      Ok(value) => value
      Err(@router.ByteResourceLimit(_))
      | Err(@router.QoS1ResourceLimit(_, _)) =>
        return [
          SendMqtt5({
            connection_id,
            packet: Suback5({
              packet_id: packet.packet_id,
              properties: [],
              reasons: authorized.map(_ => 0x97),
            }),
            close_reason: None,
          }),
        ]
      Err(_) => return self.terminate(connection_id, ProtocolError)
    }
  }
  let reasons : Array[Int] = []
  let mut index = 0
  for allowed in authorized {
    if !allowed {
      reasons.push(0x87)
    } else {
      let value = match broker_actions[0] {
        SubscriptionsApplied(applied) => applied.results[index]
        _ => return self.terminate(connection_id, ProtocolError)
      }
      index += 1
      reasons.push(
        match value {
          Granted(qos) =>
            match qos {
              @session.QoS0 => 0
              @session.QoS1 => 1
              @session.QoS2 => 2
            }
          RejectedLimit(_) => 0x97
          RejectedSharedUnsupported => 0x9e
        },
      )
    }
  }
  let actions : Array[RuntimeAction] = [
    SendMqtt5({
      connection_id,
      packet: Suback5({ packet_id: packet.packet_id, properties: [], reasons }),
      close_reason: None,
    }),
  ]
  actions.append(self.map_broker_actions(broker_actions))
  actions
}

///|
fn BrokerRuntime::handle_v5_unsubscribe(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  client_id : @session.ClientId,
  packet : @protocol.UnsubscribeV5,
) -> Array[RuntimeAction] {
  let filters : Array[@topic.TopicFilter] = []
  for text in packet.topic_filters {
    let filter = match @topic.TopicFilter::new(text) {
      Ok(value) => value
      Err(_) => return self.terminate(connection_id, ProtocolError)
    }
    filters.push(filter)
  }
  let broker_actions = match
    self.broker_state.apply(@router.Unsubscribe({ client_id, filters })) {
    Ok(value) => value
    Err(_) => return self.terminate(connection_id, ProtocolError)
  }
  let removed = match broker_actions[0] {
    UnsubscriptionsApplied(value) => value.removed
    _ => return self.terminate(connection_id, ProtocolError)
  }
  [
    SendMqtt5({
      connection_id,
      packet: Unsuback5({
        packet_id: packet.packet_id,
        properties: [],
        reasons: removed.map(value => if value { 0 } else { 0x11 }),
      }),
      close_reason: None,
    }),
  ]
}
