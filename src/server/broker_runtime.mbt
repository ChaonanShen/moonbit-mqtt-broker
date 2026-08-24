///|
pub struct BrokerRuntime {
  config : ServerConfig
  broker_state : @router.BrokerState
  connections : Map[ConnectionId, ConnectionMeta]
  active_by_client : Map[@session.ClientId, ConnectionId]
  security : @security.SecurityPolicy
  metrics : BrokerMetrics
  logger : @observability.Logger
}

///|
pub fn BrokerRuntime::new(
  config : ServerConfig,
  initial_state : @router.BrokerState,
  security? : @security.SecurityPolicy = @security.SecurityPolicy::permissive(),
  metrics? : BrokerMetrics = BrokerMetrics::new(0L),
  logger? : @observability.Logger = @observability.Logger::silent(),
) -> BrokerRuntime {
  {
    config,
    broker_state: initial_state,
    connections: Map([]),
    active_by_client: Map([]),
    security,
    metrics,
    logger,
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
pub fn BrokerRuntime::metrics(self : BrokerRuntime) -> BrokerMetrics {
  self.metrics
}

///|
fn accepted_connack_packet(session_present : Bool) -> @protocol.Packet {
  Connack({ session_present, return_code: Accepted })
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
fn close_reason_name(reason : CloseReason) -> String {
  match reason {
    NormalDisconnect => "normal_disconnect"
    ConnectRejected => "connect_rejected"
    PeerEof => "peer_eof"
    ReadFailure => "read_failure"
    WriteFailure => "write_failure"
    ProtocolError => "protocol_error"
    KeepAliveTimeout => "keep_alive_timeout"
    ConnectTimeout => "connect_timeout"
    ClientTakeover => "client_takeover"
    SlowConsumer => "slow_consumer"
    EncodeFailure => "encode_failure"
    ResourceExhausted => "resource_exhausted"
    ServerShutdown => "server_shutdown"
  }
}

///|
fn connect_return_code_name(code : @protocol.ConnectReturnCode) -> String {
  match code {
    Accepted => "accepted"
    UnacceptableProtocolVersion => "unacceptable_protocol_version"
    IdentifierRejected => "identifier_rejected"
    ServerUnavailable => "server_unavailable"
    BadUsernameOrPassword => "bad_username_or_password"
    NotAuthorized => "not_authorized"
  }
}

///|
fn BrokerRuntime::reject_connect(
  self : BrokerRuntime,
  connection_id : ConnectionId,
  code : @protocol.ConnectReturnCode,
) -> Array[RuntimeAction] {
  self.logger.log(
    @observability.LogRecord::new(
      @async.now(),
      @observability.Warn,
      "connect_rejected",
      connection_id=connection_id.value().to_string(),
      reason=connect_return_code_name(code),
    ),
  )
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
          Some(connection_id) => {
            let principal = match self.connections.get(connection_id) {
              Some(meta) => meta.principal
              None => None
            }
            if principal is Some(value) &&
              !self.security.can_read_topic(value, delivery.topic) {
              continue
            }
            match delivery.qos {
              QoS0 => {
                self.metrics.record_sent()
                actions.push(
                  SendPacket({
                    connection_id,
                    packet: Publish({
                      topic: delivery.topic.value(),
                      payload: copy_runtime_bytes(delivery.payload),
                      qos: @protocol.QoS::QoS0,
                      packet_id: None,
                      dup: delivery.dup,
                      retain: delivery.retain,
                    }),
                  }),
                )
              }
              QoS1 => {
                let packet_id = match delivery.packet_id {
                  Some(value) => @protocol.PacketId::new(value.value()).unwrap()
                  None => continue
                }
                self.metrics.record_sent()
                actions.push(
                  SendPacket({
                    connection_id,
                    packet: Publish({
                      topic: delivery.topic.value(),
                      payload: copy_runtime_bytes(delivery.payload),
                      qos: @protocol.QoS::QoS1,
                      packet_id: Some(packet_id),
                      dup: delivery.dup,
                      retain: delivery.retain,
                    }),
                  }),
                )
              }
            }
          }
        }
      DeliveryDroppedResourceLimit(_) => self.metrics.record_dropped()
      SessionExpired(client_id) =>
        self.logger.log(
          @observability.LogRecord::new(
            @async.now(),
            @observability.Info,
            "session_expired",
            message="persistent Session expired client_id=" + client_id.value(),
            client_id=client_id.value(),
            snapshot_revision=self.broker_state.snapshot_revision().to_string(),
          ),
        )
      TimeRegressionDetected(previous, current) =>
        self.logger.log(
          @observability.LogRecord::new(
            current,
            @observability.Warn,
            "time_regression",
            message="clock rollback detected previous_ms=" +
              previous.to_string() +
              " current_ms=" +
              current.to_string(),
            reason="time_regression",
          ),
        )
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
  observed_at_ms? : Int64 = -1L,
) -> Array[RuntimeAction] {
  let meta = match self.connections.get(connection_id) {
    None => return []
    Some(meta) => meta
  }
  self.connections.remove(connection_id)
  let log_client_id = match meta.phase {
    Active(value) => value.value()
    AwaitConnect => ""
  }
  let log_principal = match meta.principal {
    Some(value) => value.storage_value()
    None => ""
  }
  self.logger.log(
    @observability.LogRecord::new(
      if observed_at_ms >= 0L {
        observed_at_ms
      } else {
        @async.now()
      },
      @observability.Info,
      "connection_closed",
      connection_id=connection_id.value().to_string(),
      client_id=log_client_id,
      principal=log_principal,
      reason=close_reason_name(reason),
      snapshot_revision=self.broker_state.snapshot_revision().to_string(),
    ),
  )
  let actions : Array[RuntimeAction] = []
  match meta.phase {
    AwaitConnect => ()
    Active(client_id) => {
      if self.active_by_client.get(client_id) == Some(connection_id) {
        self.active_by_client.remove(client_id)
        match self.broker_state.session_mode(client_id) {
          Some(Persistent) =>
            ignore(
              self.broker_state.apply(
                @router.BrokerEvent::DetachSessionAt({
                  client_id,
                  detached_at_ms: if observed_at_ms >= 0L {
                    observed_at_ms
                  } else {
                    meta.last_control_at_ms
                  },
                }),
              ),
            )
          Some(Clean) =>
            ignore(
              self.broker_state.apply(
                @router.BrokerEvent::RemoveSession(client_id),
              ),
            )
          None => ()
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
              qos: will.qos,
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
  let accepted_at_ms = match self.connections.get(connection_id) {
    Some(meta) => meta.accepted_at_ms
    None => received_at_ms
  }
  let principal = match
    self.security.authenticate(packet.username, packet.password) {
    Accepted(value) => value
    BadCredentials => {
      self.metrics.record_authentication_failure()
      self.logger.log(
        @observability.LogRecord::new(
          received_at_ms,
          @observability.Warn,
          "authentication_failed",
          connection_id=connection_id.value().to_string(),
          reason="bad_credentials",
        ),
      )
      return self.reject_connect(connection_id, BadUsernameOrPassword)
    }
    NotAuthorized => {
      self.metrics.record_authentication_failure()
      self.logger.log(
        @observability.LogRecord::new(
          received_at_ms,
          @observability.Warn,
          "authentication_failed",
          connection_id=connection_id.value().to_string(),
          reason="not_authorized",
        ),
      )
      return self.reject_connect(connection_id, NotAuthorized)
    }
  }
  if !packet.clean_session && packet.client_id == "" {
    return self.reject_connect(connection_id, IdentifierRejected)
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
  match self.broker_state.session_owner(client_id) {
    Some(owner) => {
      let legacy_anonymous = owner == @security.Principal::LegacyAnonymous &&
        principal == @security.Principal::Anonymous
      if owner != principal && !legacy_anonymous {
        self.metrics.record_authentication_failure()
        self.logger.log(
          @observability.LogRecord::new(
            received_at_ms,
            @observability.Warn,
            "principal_owner_mismatch",
            connection_id=connection_id.value().to_string(),
            client_id=client_id.value(),
            principal=principal.storage_value(),
            reason="not_authorized",
          ),
        )
        return self.reject_connect(connection_id, NotAuthorized)
      }
    }
    None => ()
  }
  let stored_will = match packet.will {
    None => None
    Some(will) => {
      match will.qos {
        QoS1 => ()
        QoS2 => return self.terminate(connection_id, ProtocolError)
        QoS0 => ()
      }
      let topic = match @topic.TopicName::new(will.topic) {
        Err(_) => return self.terminate(connection_id, ProtocolError)
        Ok(value) => value
      }
      if !self.security.can_write_topic(principal, topic) {
        self.metrics.record_acl_denial()
        self.logger.log(
          @observability.LogRecord::new(
            received_at_ms,
            @observability.Warn,
            "acl_denied",
            connection_id=connection_id.value().to_string(),
            client_id=client_id.value(),
            principal=principal.storage_value(),
            reason="will_write_denied",
          ),
        )
        return self.reject_connect(connection_id, NotAuthorized)
      }
      Some({
        topic,
        payload: copy_runtime_bytes(will.payload),
        qos: qos_from_protocol(will.qos).unwrap(),
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
  let mut session_present = false
  let session_actions : Array[@router.BrokerAction] = []
  if packet.clean_session {
    if self.broker_state.has_session(client_id) {
      ignore(
        self.broker_state.apply(@router.BrokerEvent::RemoveSession(client_id)),
      )
    }
    match
      self.broker_state.apply(
        @router.BrokerEvent::CreateOwnedSessionWith({
          client_id,
          mode: @session.SessionMode::Clean,
          attached: true,
          owner: principal,
        }),
      ) {
      Err(_) => {
        actions.append(self.reject_connect(connection_id, ServerUnavailable))
        return actions
      }
      Ok(value) => session_actions.append(value)
    }
  } else {
    match self.broker_state.session_mode(client_id) {
      Some(Persistent) => {
        session_present = true
        match
          self.broker_state.apply(@router.BrokerEvent::AttachSession(client_id)) {
          Err(_) => {
            actions.append(
              self.reject_connect(connection_id, ServerUnavailable),
            )
            return actions
          }
          Ok(value) => session_actions.append(value)
        }
      }
      Some(Clean) => {
        ignore(
          self.broker_state.apply(@router.BrokerEvent::RemoveSession(client_id)),
        )
        match
          self.broker_state.apply(
            @router.BrokerEvent::CreateOwnedSessionWith({
              client_id,
              mode: @session.SessionMode::Persistent,
              attached: true,
              owner: principal,
            }),
          ) {
          Err(_) => {
            actions.append(
              self.reject_connect(connection_id, ServerUnavailable),
            )
            return actions
          }
          Ok(value) => session_actions.append(value)
        }
      }
      None =>
        match
          self.broker_state.apply(
            @router.BrokerEvent::CreateOwnedSessionWith({
              client_id,
              mode: @session.SessionMode::Persistent,
              attached: true,
              owner: principal,
            }),
          ) {
          Err(_) => {
            actions.append(
              self.reject_connect(connection_id, ServerUnavailable),
            )
            return actions
          }
          Ok(value) => session_actions.append(value)
        }
    }
  }
  self.active_by_client.set(client_id, connection_id)
  self.connections.set(connection_id, {
    id: connection_id,
    phase: Active(client_id),
    accepted_at_ms,
    last_control_at_ms: received_at_ms,
    keep_alive_seconds: packet.keep_alive,
    will: stored_will,
    principal: Some(principal),
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
  actions.push(
    SendPacket({
      connection_id,
      packet: accepted_connack_packet(session_present),
    }),
  )
  actions.append(self.map_broker_actions(session_actions))
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
  principal : @security.Principal,
  packet : @protocol.SubscribePacket,
) -> Array[RuntimeAction] {
  let entries : Array[@router.SubscribeEntry] = []
  let authorized : Array[Bool] = []
  for subscription in packet.subscriptions {
    let filter = match @topic.TopicFilter::new(subscription.topic_filter) {
      Err(_) => return self.close_protocol_error(connection_id)
      Ok(value) => value
    }
    let qos = match qos_from_protocol(subscription.requested_qos) {
      None => return self.close_protocol_error(connection_id)
      Some(value) => value
    }
    let allowed = self.security.can_read_filter(principal, filter)
    if !allowed {
      self.metrics.record_acl_denial()
      self.logger.log(
        @observability.LogRecord::new(
          @async.now(),
          @observability.Warn,
          "acl_denied",
          connection_id=connection_id.value().to_string(),
          client_id=client_id.value(),
          principal=principal.storage_value(),
          reason="subscribe_denied",
        ),
      )
    }
    authorized.push(allowed)
    if allowed {
      entries.push({ filter, qos })
    }
  }
  let broker_actions = match
    (if entries.length() == 0 {
      Ok([])
    } else {
      self.broker_state.apply(
        @router.BrokerEvent::Subscribe({ client_id, entries }),
      )
    }) {
    Err(@router.RouterError::QoS1ResourceLimit(_, _)) =>
      return self.terminate(connection_id, ResourceExhausted)
    Err(_) => return self.close_protocol_error(connection_id)
    Ok(value) => value
  }
  let actions : Array[RuntimeAction] = []
  if broker_actions.length() == 0 {
    return [
      SendPacket({
        connection_id,
        packet: Suback({
          packet_id: packet.packet_id,
          return_codes: authorized.map(_ => Failure),
        }),
      }),
    ]
  }
  match broker_actions[0] {
    SubscriptionsApplied(applied) => {
      let return_codes : Array[@protocol.SubackReturnCode] = []
      let mut result_index = 0
      for allowed in authorized {
        if !allowed {
          return_codes.push(Failure)
        } else {
          let result = applied.results[result_index]
          result_index = result_index + 1
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
  principal : @security.Principal,
  packet : @protocol.Packet,
) -> Array[RuntimeAction] {
  match packet {
    Pingreq => [SendPacket({ connection_id, packet: Pingresp })]
    Disconnect => self.terminate(connection_id, NormalDisconnect)
    Publish(publish_packet) => {
      self.metrics.record_received()
      let incoming_packet_id : @protocol.PacketId? = match publish_packet.qos {
        QoS0 => {
          if publish_packet.packet_id is Some(_) || publish_packet.dup {
            return self.close_protocol_error(connection_id)
          }
          None
        }
        QoS1 =>
          match publish_packet.packet_id {
            Some(value) => Some(value)
            None => return self.close_protocol_error(connection_id)
          }
        QoS2 => return self.close_protocol_error(connection_id)
      }
      let qos = if incoming_packet_id is Some(_) {
        @session.DeliveryQoS::QoS1
      } else {
        @session.DeliveryQoS::QoS0
      }
      let topic = match @topic.TopicName::new(publish_packet.topic) {
        Err(_) => return self.close_protocol_error(connection_id)
        Ok(value) => value
      }
      if !self.security.can_write_topic(principal, topic) {
        self.metrics.record_acl_denial()
        self.metrics.record_dropped()
        self.logger.log(
          @observability.LogRecord::new(
            @async.now(),
            @observability.Warn,
            "acl_denied",
            connection_id=connection_id.value().to_string(),
            client_id=client_id.value(),
            principal=principal.storage_value(),
            reason="publish_write_denied",
          ),
        )
        return match incoming_packet_id {
          Some(packet_id) =>
            [SendPacket({ connection_id, packet: Puback(packet_id) })]
          None => []
        }
      }
      let result = self.publish({
        origin: Client(client_id),
        topic,
        payload: copy_runtime_bytes(publish_packet.payload),
        qos,
        retain: publish_packet.retain,
      })
      match result {
        Ok(deliveries) => {
          let actions : Array[RuntimeAction] = []
          match incoming_packet_id {
            Some(packet_id) =>
              actions.push(
                SendPacket({ connection_id, packet: Puback(packet_id) }),
              )
            None => ()
          }
          actions.append(deliveries)
          actions
        }
        Err(@router.RouterError::QoS1ResourceLimit(_, _)) =>
          self.terminate(connection_id, ResourceExhausted)
        Err(_) => self.close_protocol_error(connection_id)
      }
    }
    Puback(packet_id) => {
      let session_packet_id = @session.SessionPacketId::new(packet_id.value()).unwrap()
      match
        self.broker_state.apply(
          @router.BrokerEvent::Puback({
            client_id,
            packet_id: session_packet_id,
          }),
        ) {
        Ok(actions) => self.map_broker_actions(actions)
        Err(_) => self.close_protocol_error(connection_id)
      }
    }
    Subscribe(subscribe_packet) =>
      self.handle_subscribe(
        connection_id, client_id, principal, subscribe_packet,
      )
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
      let principal = meta.principal.unwrap()
      self.handle_active_packet(
        event.connection_id,
        client_id,
        principal,
        event.packet,
      )
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
  match self.broker_state.apply(@router.BrokerEvent::ExpireSessions(now_ms)) {
    Ok(expiration_actions) =>
      actions.append(self.map_broker_actions(expiration_actions))
    Err(_) => ()
  }
  for pair in expired {
    let (connection_id, reason) = pair
    actions.append(self.terminate(connection_id, reason))
  }
  actions
}

///|
fn BrokerRuntime::emit_system_metric(
  self : BrokerRuntime,
  topic_value : String,
  value : String,
) -> Array[RuntimeAction] {
  let topic = @topic.TopicName::new(topic_value).unwrap()
  let payload = @utf8.encode(value)
  let actions : Array[RuntimeAction] = []
  for client_id in self.broker_state.system_subscribers(topic) {
    let connection_id = match self.active_by_client.get(client_id) {
      None => continue
      Some(value) => value
    }
    let meta = match self.connections.get(connection_id) {
      Some(value) => value
      None => continue
    }
    let principal = match meta.principal {
      Some(value) => value
      None => continue
    }
    if !self.security.can_read_topic(principal, topic) {
      continue
    }
    actions.push(
      SendPacket({
        connection_id,
        packet: Publish({
          topic: topic_value,
          payload,
          qos: @protocol.QoS::QoS0,
          packet_id: None,
          dup: false,
          retain: false,
        }),
      }),
    )
  }
  actions
}

///|
fn BrokerRuntime::emit_system_metrics(
  self : BrokerRuntime,
  event : EmitSystemMetricsEvent,
) -> Array[RuntimeAction] {
  let state = self.broker_state
  let values : Array[(String, String)] = [
    ("version", "0.1.0"),
    ("uptime_seconds", self.metrics.uptime_seconds(event.now_ms).to_string()),
    ("clients/connected", self.active_by_client.length().to_string()),
    ("sessions/count", state.session_count().to_string()),
    ("subscriptions/count", state.subscription_count().to_string()),
    ("retained/count", state.retained_count().to_string()),
    ("qos1/inflight", state.inflight_count().to_string()),
    ("qos1/pending", state.pending_qos1_count().to_string()),
    ("messages/received", self.metrics.messages_received().to_string()),
    ("messages/sent", self.metrics.messages_sent().to_string()),
    ("messages/dropped", self.metrics.messages_dropped().to_string()),
    ("auth/failures", self.metrics.authentication_failures().to_string()),
    ("acl/denials", self.metrics.acl_denials().to_string()),
    (
      "tls/handshake_failures",
      self.metrics.tls_handshake_failures().to_string(),
    ),
    ("persistence/state", event.persistence_state),
  ]
  let actions : Array[RuntimeAction] = []
  for item in values {
    let (suffix, value) = item
    actions.append(self.emit_system_metric("$SYS/broker/" + suffix, value))
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
        principal: None,
      })
      []
    }
    PacketReceived(packet) => self.handle_packet(packet)
    TransportClosed(closed) =>
      self.terminate(
        closed.connection_id,
        closed.reason,
        observed_at_ms=closed.observed_at_ms,
      )
    CheckDeadlines(now_ms) => self.check_deadlines(now_ms)
    EmitSystemMetrics(event) => self.emit_system_metrics(event)
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
  if self.broker_state.attached_session_count() !=
    self.active_by_client.length() {
    return Err(
      RuntimeInvariantViolation(
        "attached session count does not match active clients",
      ),
    )
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
    if self.broker_state.session_attached(client_id) != Some(true) {
      return Err(RuntimeInvariantViolation("active client session is detached"))
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
