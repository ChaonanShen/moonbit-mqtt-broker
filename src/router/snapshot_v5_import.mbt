///|
fn v5_strip_message(value : SnapshotMessageV5) -> SnapshotMessageV3 {
  {
    topic: value.topic,
    payload: copy_router_bytes(value.payload),
    retain: value.retain,
    qos: value.qos,
  }
}

///|
fn v5_restore_deadline(
  clock : SnapshotClockV5,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  floor_wall_ms : Int64,
) -> Result[@session.Deadline, SnapshotError] {
  match
    @session.Deadline::restore(
      now_mono_ms,
      now_wall_ms,
      floor_wall_ms,
      clock.remaining_ms,
      clock.deadline_wall_ms,
    ) {
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidState("invalid restored V5 deadline"))
  }
}

///|
fn v5_restore_message(
  saved : SnapshotMessageV5,
  delivery_id : Int64,
  identifiers : Array[UInt],
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  floor_wall_ms : Int64,
) -> Result[@session.SessionMessage, SnapshotError] {
  let topic = match @topic.TopicName::new(saved.topic) {
    Ok(value) => value
    Err(_) => return Err(InvalidTopic(saved.topic))
  }
  let response_topic = match saved.properties.response_topic {
    None => None
    Some(value) =>
      match @topic.TopicName::new(value) {
        Ok(topic) => Some(topic)
        Err(_) => return Err(InvalidTopic(value))
      }
  }
  let publisher_client_id = match saved.publisher_client_id {
    None => None
    Some(value) =>
      match @session.ClientId::new(value) {
        Ok(id) => Some(id)
        Err(_) => return Err(InvalidClientId(value))
      }
  }
  let expiry = match saved.expiry_clock {
    None => None
    Some(clock) =>
      Some(
        match
          v5_restore_deadline(clock, now_mono_ms, now_wall_ms, floor_wall_ms) {
          Ok(value) => value
          Err(error) => return Err(error)
        },
      )
  }
  let qos = match qos_from_snapshot(saved.qos) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let metadata : @session.MessageMetadata = {
    payload_format: saved.properties.payload_format,
    content_type: saved.properties.content_type,
    response_topic,
    correlation_data: saved.properties.correlation_data.map(copy_router_bytes),
    user_properties: saved.properties.user_properties.copy(),
    publisher_client_id,
    expiry,
  }
  let ids : Array[Int] = []
  for id in identifiers {
    if id == 0U || id > 268435455U {
      return Err(InvalidState("invalid subscription identifier"))
    }
    ids.push(id.reinterpret_as_int())
  }
  Ok(
    @session.SessionMessage::new(
      topic,
      saved.payload,
      saved.retain,
      qos~,
      metadata~,
      subscription_identifiers=ids,
      delivery_id~,
    ),
  )
}

///|
pub fn BrokerState::from_snapshot_v5(
  config : BrokerConfig,
  saved : BrokerSnapshotV5,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  ledger? : @budget.Ledger,
  recover_armed_wills? : Bool = true,
) -> Result[BrokerState, SnapshotError] {
  if now_mono_ms < 0L || now_wall_ms < 0L || !saved.groups.is_empty() {
    return Err(InvalidState("unsupported V5 snapshot state"))
  }
  let stripped_sessions : Array[SnapshotSessionV3] = []
  for session in saved.sessions {
    if session.retention == @session.DropOnClose {
      return Err(InvalidState("drop-on-close session cannot be durable"))
    }
    stripped_sessions.push({
      client_id: session.client_id,
      owner_principal: session.owner_principal,
      detached_at_ms: session.detached_at_wall_ms.unwrap_or(0L),
      next_packet_id: session.next_packet_id,
      subscriptions: session.subscriptions.map(item => {
        filter: item.wire_filter,
        qos: item.qos,
      }),
      inbound_qos2: session.inbound_qos2.map(item => item.packet_id),
      inflight: session.inflight.map(item => {
        packet_id: item.packet_id,
        phase: item.phase,
        message: item.message.map(v5_strip_message),
      }),
      pending: session.pending.map(item => v5_strip_message(item.message)),
    })
  }
  let stripped_retained : Array[SnapshotRetainedV3] = saved.retained.map(item => {
    topic: item.message.topic,
    payload: copy_router_bytes(item.message.payload),
    qos: item.message.qos,
  })
  let state = match
    BrokerState::from_snapshot(
      config,
      { version: 3, sessions: stripped_sessions, retained: stripped_retained },
      ledger?,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for session in saved.sessions {
    let client_id = @session.ClientId::new(session.client_id).unwrap()
    let owner = @security.Principal::from_storage_value(session.owner_principal).unwrap()
    let restored_inflight : Array[@session.OutboundInflight] = []
    for item in session.inflight {
      let message = match item.message {
        None => None
        Some(value) =>
          Some(
            match
              v5_restore_message(
                value,
                item.delivery_id,
                item.subscription_identifiers,
                now_mono_ms,
                now_wall_ms,
                saved.clock_floor_wall_ms,
              ) {
              Ok(message) => message
              Err(error) => return Err(error)
            },
          )
      }
      let packet_id = @session.SessionPacketId::new(item.packet_id).unwrap()
      restored_inflight.push({
        packet_id,
        delivery_id: item.delivery_id,
        started: item.started,
        subscription_identifiers: item.subscription_identifiers.map(id => {
          id.reinterpret_as_int()
        }),
        message,
        phase: match item.phase {
          1 => AwaitPuback
          2 => AwaitPubrec
          _ => AwaitPubcomp
        },
      })
    }
    let restored_pending : Array[@session.SessionMessage] = []
    for item in session.pending {
      match
        v5_restore_message(
          item.message,
          item.delivery_id,
          item.subscription_identifiers,
          now_mono_ms,
          now_wall_ms,
          saved.clock_floor_wall_ms,
        ) {
        Ok(value) => restored_pending.push(value)
        Err(error) => return Err(error)
      }
    }
    let expiry_deadline = match session.retention {
      @session.FiniteV5(seconds) if session.attached_at_capture =>
        match
          @session.Deadline::from_seconds(now_mono_ms, now_wall_ms, seconds) {
          Ok(value) => Some(value)
          Err(_) => return Err(InvalidState("recovery expiry overflow"))
        }
      @session.FiniteV5(_) =>
        match session.session_expiry_clock {
          Some(clock) =>
            Some(
              match
                v5_restore_deadline(
                  clock,
                  now_mono_ms,
                  now_wall_ms,
                  saved.clock_floor_wall_ms,
                ) {
                Ok(value) => value
                Err(error) => return Err(error)
              },
            )
          None => return Err(InvalidState("finite session lacks expiry clock"))
        }
      _ => None
    }
    let detached_at_ms = if session.attached_at_capture {
      now_wall_ms
    } else {
      session.detached_at_wall_ms.unwrap_or(0L)
    }
    let inbound_qos2 = session.inbound_qos2.map(item => {
      @session.SessionPacketId::new(item.packet_id).unwrap()
    })
    let restored = match
      @session.ClientSession::restore_v5(
        client_id,
        session.next_packet_id,
        restored_inflight,
        restored_pending,
        owner,
        detached_at_ms,
        inbound_qos2,
        session.retention,
        session.last_protocol,
        session.state_revision,
        expiry_deadline,
      ) {
      Ok(value) => value
      Err(_) => return Err(InvalidState("invalid restored V5 session"))
    }
    state.sessions.set(client_id, restored)
    state.session_incarnations.set(client_id, session.incarnation)
    for item in session.subscriptions {
      if item.kind == 1 ||
        item.group_id is Some(_) ||
        item.group_incarnation is Some(_) ||
        item.inner_filter is Some(_) {
        return Err(InvalidState("shared state is unavailable"))
      }
      let filter = @topic.TopicFilter::new(item.wire_filter).unwrap()
      let binding : SubscriptionBinding = {
        identity: item.identity,
        filter,
        qos: qos_from_snapshot(item.qos).unwrap(),
        no_local: item.no_local,
        retain_as_published: item.retain_as_published,
        retain_handling: item.retain_handling,
        subscription_identifier: item.subscription_identifier.map(id => {
          id.reinterpret_as_int()
        }),
      }
      state.subscriptions.restore_binding(client_id, binding)
    }
  }
  for retained in saved.retained {
    let topic = @topic.TopicName::new(retained.message.topic).unwrap()
    let restored = match
      v5_restore_message(
        retained.message,
        0L,
        [],
        now_mono_ms,
        now_wall_ms,
        saved.clock_floor_wall_ms,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if !state.retained.put(
        topic,
        restored.payload,
        restored.qos,
        config.max_retained_messages(),
        metadata=restored.metadata,
      ) ||
      !state.retained.restore_revision(topic, retained.revision) {
      return Err(InvalidState("retained recovery failed"))
    }
  }
  for stored_will in saved.wills {
    let client_id = match @session.ClientId::new(stored_will.client_id) {
      Ok(value) => value
      Err(_) => return Err(InvalidClientId(stored_will.client_id))
    }
    let owner = match
      @security.Principal::from_storage_value(stored_will.owner_principal) {
      Some(value) => value
      None => return Err(InvalidState("invalid Will owner"))
    }
    let message = match
      v5_restore_message(
        stored_will.message_template,
        0L,
        [],
        now_mono_ms,
        now_wall_ms,
        saved.clock_floor_wall_ms,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let due = match stored_will.due_clock {
      None => None
      Some(clock) =>
        Some(
          match
            v5_restore_deadline(
              clock,
              now_mono_ms,
              now_wall_ms,
              saved.clock_floor_wall_ms,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          },
        )
    }
    let template : Mqtt5WillTemplate = {
      topic: message.topic,
      payload: message.payload,
      qos: message.qos,
      retain: message.retain,
      metadata: message.metadata,
      delay_seconds: stored_will.delay_seconds,
      message_expiry_seconds: stored_will.will_message_expiry_seconds,
    }
    let record : Mqtt5WillRecord = {
      id: stored_will.id,
      owner,
      client_id,
      session_incarnation: stored_will.session_incarnation,
      state: if stored_will.state == 0 {
        WillArmed
      } else {
        WillPending
      },
      template,
      trigger_wall_ms: stored_will.trigger_wall_ms,
      due,
      policy_sequence: stored_will.policy_sequence,
      revision: stored_will.revision,
    }
    if record.state == WillArmed {
      if state.session_incarnation(client_id) !=
        Some(record.session_incarnation) ||
        state.active_will_by_client.contains(client_id) {
        return Err(InvalidState("orphan or duplicate armed Will"))
      }
      state.active_will_by_client.set(client_id, record.id)
    }
    let cost = @budget.message_cost(
        record.template.topic.value(),
        record.template.payload.length().to_int64(),
      ).unwrap() +
      record.template.metadata.cost() +
      256L
    let pool = state.resources.ledger
      .pool(Will, config.resources().get("max_will_bytes_total"))
      .unwrap()
    let ticket = match pool.reserve(cost) {
      Ok(value) => value
      Err(_) => return Err(LimitExceeded("restored Will byte budget"))
    }
    ticket.commit().unwrap()
    state.will_tickets.set(record.id, ticket)
    state.wills.set(record.id, record)
  }
  state.next_will_id = saved.next_will_id
  for will in saved.wills {
    if recover_armed_wills && will.state == 0 {
      let client_id = @session.ClientId::new(will.client_id).unwrap()
      let retention = state.sessions.get(client_id).unwrap().retention()
      if !state.trigger_will(will.id, now_mono_ms, now_wall_ms, retention) {
        return Err(InvalidState("recovery Will transition failed"))
      }
    }
  }
  if !state.subscriptions.ensure_next_identity(saved.next_subscription_identity) ||
    !state.retained.ensure_next_revision(saved.next_retained_revision) {
    return Err(InvalidState("invalid V5 high-water mark"))
  }
  state.next_delivery_id = saved.next_delivery_id
  state.next_session_incarnation = saved.next_session_incarnation
  state.storage_v5 = true
  state.clock_floor_wall_ms = if now_wall_ms > saved.clock_floor_wall_ms {
    now_wall_ms
  } else {
    saved.clock_floor_wall_ms
  }
  match state.settle_resources() {
    Ok(_) => ()
    Err(_) => return Err(LimitExceeded("V5 restored metadata exceeds budget"))
  }
  match state.check_invariants() {
    Ok(_) => Ok(state)
    Err(_) => Err(InvalidState("V5 restored broker invariant failed"))
  }
}
