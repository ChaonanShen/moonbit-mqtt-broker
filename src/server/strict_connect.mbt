///|
pub fn BrokerRuntime::prepare_strict_accepted_connect(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  packet : @protocol.ConnectPacket,
  received_at_ms : Int64,
  principal : @security.Principal,
  generations : Map[@session.ClientId, Int64],
  proposed_generation : Int64,
) -> StrictPacketPlan {
  let current = match self.connections.get(connection_id) {
    Some(value) if value.phase is AwaitConnect ||
      value.phase is Authenticating(_) => value
    _ => return StrictImmediate([])
  }
  if !packet.clean_session && packet.client_id == "" {
    return StrictImmediate(
      self.reject_connect(connection_id, IdentifierRejected),
    )
  }
  let client_name = if packet.client_id == "" {
    "moonbit-auto-" + connection_id.value().to_string()
  } else {
    packet.client_id
  }
  let client_id = match @session.ClientId::new(client_name) {
    Ok(value) => value
    Err(_) =>
      return StrictImmediate(
        self.reject_connect(connection_id, IdentifierRejected),
      )
  }
  let takeover_id = match self.active_by_client.get(client_id) {
    Some(old_id) if old_id != connection_id => Some(old_id)
    _ => None
  }
  match self.broker_state.session_owner(client_id) {
    Some(owner) => {
      let legacy_anonymous = owner == @security.Principal::LegacyAnonymous &&
        principal == @security.Principal::Anonymous
      if owner != principal && !legacy_anonymous {
        return StrictImmediate(
          self.reject_connect(connection_id, NotAuthorized),
        )
      }
    }
    None => ()
  }
  let v5_plan = self.v5_pending.get(connection_id)
  if v5_plan is Some(plan) &&
    @protocol.encode_v5(
      mqtt5_connack(plan, self.config, false),
      @protocol.ServerToClient,
      plan.peer_max_packet_bytes,
    )
    is Err(_) {
    return StrictImmediate(
      self.reject_connect(connection_id, ServerUnavailable),
    )
  }
  let prepared_v5_will = match v5_plan {
    Some(plan) =>
      match self.prepare_v5_will(plan, client_id, principal) {
        Ok(value) => value
        Err(reason) =>
          return StrictImmediate(
            self.reject_mqtt5_connect(connection_id, reason),
          )
      }
    None => None
  }
  let v5_will_id = prepared_v5_will.map(value => value.id())
  let mut will_ticket : @budget.Ticket? = None
  let stored_will : StoredWill? = match packet.will {
    None => None
    Some(will) => {
      let topic = match @topic.TopicName::new(will.topic) {
        Ok(value) => value
        Err(_) => return StrictClose(connection_id, ProtocolError)
      }
      if !self.security.can_write_topic(principal, topic) {
        self.metrics.record_acl_denial()
        return StrictImmediate(
          self.reject_connect(connection_id, NotAuthorized),
        )
      }
      let limits = self.config.broker_config().resources()
      let ledger = self.broker_state.resource_ledger()
      let pool = ledger
        .pool(Will, limits.get("max_will_bytes_total"))
        .unwrap()
        .with_account(
          ledger
          .account(Connection, limits.get("max_will_bytes_per_connection"))
          .unwrap(),
        )
        .unwrap()
      let cost = @budget.message_cost(
        will.topic,
        will.payload.length().to_int64(),
      ).unwrap()
      will_ticket = match pool.reserve(cost) {
        Ok(value) => {
          value.commit().unwrap()
          Some(value)
        }
        Err(_) =>
          return StrictImmediate(
            self.reject_connect(connection_id, ServerUnavailable),
          )
      }
      Some({
        topic,
        payload: copy_runtime_bytes(will.payload),
        qos: qos_from_protocol(will.qos).unwrap(),
        retain: will.retain,
      })
    }
  }
  let mode = if v5_plan is Some(plan) {
    if plan.retention == @session.DropOnClose {
      @session.Clean
    } else {
      @session.Persistent
    }
  } else if packet.clean_session {
    @session.Clean
  } else {
    @session.Persistent
  }
  let old_generation = generations.get(client_id).unwrap_or(0L)
  let restoring = if v5_plan is Some(plan) {
    plan.resume_decision == @session.ResumeExisting &&
    self.broker_state.session_mode(client_id) == Some(@session.Persistent)
  } else {
    mode == @session.Persistent &&
    self.broker_state.session_mode(client_id) == Some(@session.Persistent)
  }
  let new_generation = if mode == @session.Persistent {
    if restoring {
      old_generation
    } else {
      proposed_generation
    }
  } else {
    0L
  }
  let activation_result = match v5_plan {
    Some(plan) =>
      self.broker_state.prepare_durable_activation(
        client_id,
        mode,
        principal,
        old_generation,
        new_generation,
        v5_resume=plan.resume_decision == @session.ResumeExisting,
        v5_retention=plan.retention,
        now_mono_ms=@budget.monotonic_ms(),
      )
    None =>
      self.broker_state.prepare_durable_activation(
        client_id, mode, principal, old_generation, new_generation,
      )
  }
  let activation = match activation_result {
    Ok(value) => value
    Err(_) => {
      release_optional(will_ticket)
      if prepared_v5_will is Some(value) {
        self.broker_state.cancel_prepared_will(value)
      }
      return StrictImmediate(
        self.reject_connect(connection_id, ServerUnavailable),
      )
    }
  }
  let session_present = activation.session_present()
  let accepted_at_ms = current.accepted_at_ms
  let keep_alive_seconds = packet.keep_alive
  let mutation = match prepared_v5_will {
    Some(value) => V5ActivationWithWill(activation, value, self.broker_state)
    None => ActivationWithWill(activation, will_ticket)
  }
  StrictPrepared(mutation, broker_actions => {
    if self.connections.get(connection_id) is None {
      release_optional(will_ticket)
      return []
    }
    if !session_present {
      self.admission.reset_publisher(client_id)
    }
    if will_ticket is Some(ticket) {
      self.will_tickets.set(connection_id, ticket)
    }
    self.active_by_client.set(client_id, connection_id)
    self.retain_policy_epoch(self.policy_epoch)
    self.connections.set(connection_id, {
      id: connection_id,
      phase: Active(client_id),
      accepted_at_ms,
      last_control_at_ms: received_at_ms,
      keep_alive_seconds,
      will: stored_will,
      principal: Some(principal),
      policy_epoch: self.policy_epoch,
    })
    self.logger.log(
      @observability.LogRecord::new(
        received_at_ms,
        @observability.Info,
        "client_connected",
        connection_id=connection_id.value().to_string(),
        client_id=client_id.value(),
        principal=principal.storage_value(),
        snapshot_revision=self.broker_state.snapshot_revision().to_string(),
      ),
    )
    let actions : Array[RuntimeAction] = []
    if takeover_id is Some(old_id) {
      actions.append(
        self.finish_strict_transport_close({
          connection_id: old_id,
          reason: ClientTakeover,
          observed_at_ms: received_at_ms,
        }),
      )
    }
    if v5_plan is Some(plan) {
      self.v5_pending.remove(connection_id)
      self.v5_active.set(connection_id, plan)
      if v5_will_id is Some(value) {
        self.v5_will_ids.set(connection_id, value)
      }
      self.broker_state.enable_v5_storage()
      self.inbound_aliases.set(connection_id, Map([]))
      actions.push(
        SendMqtt5({
          rx_permit: None,
          connection_id,
          packet: mqtt5_connack(plan, self.config, session_present),
          close_reason: None,
        }),
      )
    } else {
      actions.push(
        SendPacket({
          connection_id,
          packet: accepted_connack_packet(session_present),
        }),
      )
    }
    actions.append(self.map_broker_actions(broker_actions))
    actions
  })
}

///|
pub fn BrokerRuntime::prepare_strict_v5_connect(
  self : BrokerRuntime,
  event : Mqtt5PacketReceivedEvent,
  generations : Map[@session.ClientId, Int64],
  proposed_generation : Int64,
) -> StrictPacketPlan {
  if event.rx_error is Some(reason) {
    return StrictImmediate(
      self.reject_mqtt5_connect(event.connection_id, reason),
    )
  }
  let connect = match event.packet {
    @protocol.Connect5(value) => value
    _ => return StrictClose(event.connection_id, ProtocolError)
  }
  if !self.config.protocol_config().mqtt5_enabled {
    return StrictImmediate(self.reject_mqtt5_connect(event.connection_id, 0x84))
  }
  let plan = match self.v5_pending.get(event.connection_id) {
    Some(value) => value
    None =>
      match
        normalize_mqtt5_connect(connect, self.config, client_id => {
          self.broker_state.has_session(
            @session.ClientId::new(client_id).unwrap(),
          )
        }) {
        Ok(value) => value
        Err(error) =>
          return StrictImmediate(
            self.reject_mqtt5_connect(event.connection_id, error.reason),
          )
      }
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
  self.prepare_strict_connect_packet(
    {
      connection_id: event.connection_id,
      packet: Connect(legacy),
      received_at_ms: event.received_at_ms,
    },
    generations,
    proposed_generation,
  )
}
