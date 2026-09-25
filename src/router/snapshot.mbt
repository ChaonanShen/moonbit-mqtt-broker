///|
pub(all) struct SnapshotSubscriptionV3 {
  filter : String
  qos : Int
} derive(Eq, Debug)

///|
pub(all) struct SnapshotMessageV3 {
  topic : String
  payload : Bytes
  retain : Bool
  qos : Int
} derive(Eq, Debug)

///|
pub(all) struct SnapshotInflightV3 {
  packet_id : Int
  phase : Int
  message : SnapshotMessageV3?
} derive(Eq, Debug)

///|
pub(all) struct SnapshotSessionV3 {
  client_id : String
  owner_principal : String
  detached_at_ms : Int64
  next_packet_id : Int
  subscriptions : Array[SnapshotSubscriptionV3]
  inbound_qos2 : Array[Int]
  inflight : Array[SnapshotInflightV3]
  pending : Array[SnapshotMessageV3]
} derive(Eq, Debug)

///|
pub(all) struct SnapshotRetainedV3 {
  topic : String
  payload : Bytes
  qos : Int
} derive(Eq, Debug)

///|
pub(all) struct BrokerSnapshotV3 {
  version : Int
  sessions : Array[SnapshotSessionV3]
  retained : Array[SnapshotRetainedV3]
} derive(Eq, Debug)

///|
pub(all) enum SnapshotError {
  UnsupportedVersion(Int)
  InvalidClientId(String)
  InvalidTopic(String)
  InvalidFilter(String)
  InvalidQoS(Int)
  InvalidPacketId(Int)
  DuplicateSession(String)
  DuplicateSubscription(String, String)
  DuplicateRetained(String)
  LimitExceeded(String)
  InvalidState(String)
} derive(Eq, Debug)

///|
fn snapshot_qos(qos : @session.DeliveryQoS) -> Int {
  match qos {
    QoS0 => 0
    QoS1 => 1
    QoS2 => 2
  }
}

///|
fn qos_from_snapshot(
  value : Int,
) -> Result[@session.DeliveryQoS, SnapshotError] {
  match value {
    0 => Ok(QoS0)
    1 => Ok(QoS1)
    2 => Ok(QoS2)
    _ => Err(InvalidQoS(value))
  }
}

///|
fn snapshot_message(message : @session.SessionMessage) -> SnapshotMessageV3 {
  {
    topic: message.topic.value(),
    payload: copy_router_bytes(message.payload),
    retain: message.retain,
    qos: snapshot_qos(message.qos),
  }
}

///|
fn session_message_from_snapshot(
  message : SnapshotMessageV3,
) -> Result[@session.SessionMessage, SnapshotError] {
  if message.qos != 1 && message.qos != 2 {
    return Err(InvalidQoS(message.qos))
  }
  let topic = match @topic.TopicName::new(message.topic) {
    Ok(value) => value
    Err(_) => return Err(InvalidTopic(message.topic))
  }
  Ok(
    @session.SessionMessage::new(
      topic,
      copy_router_bytes(message.payload),
      message.retain,
      qos=qos_from_snapshot(message.qos).unwrap(),
    ),
  )
}

///|
fn BrokerState::snapshot_session_candidate(
  self : BrokerState,
  client_id : @session.ClientId,
  session : @session.ClientSession,
  planned_subscriptions? : Array[SnapshotSubscriptionV3],
) -> SnapshotSessionV3 {
  let subscriptions = match planned_subscriptions {
    Some(value) => value.copy()
    None => {
      let records : Array[SnapshotSubscriptionV3] = []
      for record in self.subscriptions.records_for(client_id) {
        records.push({
          filter: record.filter.value(),
          qos: snapshot_qos(record.qos),
        })
      }
      records
    }
  }
  let inflight = session
    .inflight()
    .map(item => {
      packet_id: item.packet_id.value(),
      phase: match item.phase {
        AwaitPuback => 1
        AwaitPubrec => 2
        AwaitPubcomp => 3
      },
      message: item.message.map(snapshot_message),
    })
  let pending = session.pending().map(snapshot_message)
  {
    client_id: client_id.value(),
    owner_principal: session.owner().storage_value(),
    detached_at_ms: session.detached_at_ms().unwrap_or(0L),
    next_packet_id: session.next_packet_id(),
    subscriptions,
    inbound_qos2: session.inbound_qos2().map(id => id.value()),
    inflight,
    pending,
  }
}

///|
pub fn BrokerState::export_session_snapshot(
  self : BrokerState,
  client_id : @session.ClientId,
) -> SnapshotSessionV3? {
  match self.sessions.get(client_id) {
    Some(session) if session.mode() == @session.SessionMode::Persistent =>
      Some(self.snapshot_session_candidate(client_id, session))
    _ => None
  }
}

///|
pub fn BrokerState::export_retained_snapshot(
  self : BrokerState,
  topic : @topic.TopicName,
) -> SnapshotRetainedV3? {
  self.retained
  .peek(topic)
  .map(message => {
    topic: topic.value(),
    payload: copy_router_bytes(message.payload),
    qos: snapshot_qos(message.qos),
  })
}

///|
pub fn BrokerState::export_snapshot(self : BrokerState) -> BrokerSnapshotV3 {
  let client_ids : Array[@session.ClientId] = []
  for client_id, session in self.sessions {
    if session.mode() == @session.SessionMode::Persistent {
      client_ids.push(client_id)
    }
  }
  client_ids.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.value(), right.value())
  })
  let sessions : Array[SnapshotSessionV3] = []
  for client_id in client_ids {
    sessions.push(
      self.snapshot_session_candidate(
        client_id,
        self.sessions.get(client_id).unwrap(),
      ),
    )
  }
  let retained : Array[SnapshotRetainedV3] = []
  for message in self.retained.all_messages() {
    retained.push({
      topic: message.topic.value(),
      payload: copy_router_bytes(message.payload),
      qos: snapshot_qos(message.qos),
    })
  }
  { version: 3, sessions, retained }
}

///|
pub fn BrokerState::from_snapshot(
  config : BrokerConfig,
  snapshot : BrokerSnapshotV3,
  ledger? : @budget.Ledger,
) -> Result[BrokerState, SnapshotError] {
  if snapshot.version != 1 && snapshot.version != 2 && snapshot.version != 3 {
    return Err(UnsupportedVersion(snapshot.version))
  }
  if snapshot.sessions.length() > config.max_sessions() {
    return Err(LimitExceeded("session limit exceeded"))
  }
  if snapshot.retained.length() > config.max_retained_messages() {
    return Err(LimitExceeded("retained limit exceeded"))
  }
  let state = BrokerState::new(config, ledger?)
  let seen_sessions : Map[@session.ClientId, Bool] = Map([])
  let mut total_inflight = 0
  let mut total_pending = 0
  let mut total_inbound = 0
  for saved in snapshot.sessions {
    let client_id = match @session.ClientId::new(saved.client_id) {
      Ok(value) => value
      Err(_) => return Err(InvalidClientId(saved.client_id))
    }
    if seen_sessions.get(client_id) is Some(_) {
      return Err(DuplicateSession(saved.client_id))
    }
    seen_sessions.set(client_id, true)
    let owner = if snapshot.version == 1 {
      @security.Principal::LegacyAnonymous
    } else {
      match @security.Principal::from_storage_value(saved.owner_principal) {
        Some(value) => value
        None => return Err(InvalidState("invalid Session owner Principal"))
      }
    }
    if saved.detached_at_ms < 0L {
      return Err(InvalidState("negative Session detach timestamp"))
    }
    if saved.inflight.length() > config.max_inflight_per_session() {
      return Err(LimitExceeded("per-session inflight limit exceeded"))
    }
    if saved.pending.length() > config.max_pending_qos1_per_session() {
      return Err(LimitExceeded("per-session pending limit exceeded"))
    }
    total_inflight = total_inflight + saved.inflight.length()
    total_pending = total_pending + saved.pending.length()
    if total_inflight > config.max_inflight_total() {
      return Err(LimitExceeded("total inflight limit exceeded"))
    }
    if total_pending > config.max_pending_qos1_total() {
      return Err(LimitExceeded("total pending limit exceeded"))
    }
    let mut saved_inflight_bytes = 0L
    let mut saved_pending_bytes = 0L
    let mut saved_subscription_bytes = 0L
    for item in saved.inflight {
      let cost = match item.message {
        None => 64L
        Some(m) =>
          @budget.message_cost(m.topic, m.payload.length().to_int64()).unwrap()
      }
      saved_inflight_bytes = @budget.checked_add(saved_inflight_bytes, cost).unwrap()
    }
    for m in saved.pending {
      let cost = @budget.message_cost(m.topic, m.payload.length().to_int64()).unwrap()
      if cost > config.resources.get("max_inflight_bytes_per_session") {
        return Err(
          LimitExceeded("pending message cannot fit inflight byte budget"),
        )
      }
      saved_pending_bytes = @budget.checked_add(saved_pending_bytes, cost).unwrap()
    }
    for subscription in saved.subscriptions {
      saved_subscription_bytes = @budget.checked_add(
        saved_subscription_bytes,
        @budget.subscription_cost(subscription.filter),
      ).unwrap()
    }
    match
      state.resources.add_owner(client_id, {
        inflight: saved_inflight_bytes,
        pending: saved_pending_bytes,
        inbound: saved.inbound_qos2.length().to_int64() * 64L,
        metadata: @budget.identity_cost(saved.client_id, owner.storage_value()),
        subscriptions: saved_subscription_bytes,
      }) {
      Err(_) => return Err(LimitExceeded("snapshot session byte budget"))
      Ok(_) => ()
    }
    let restored_inflight : Array[@session.OutboundInflight] = []
    let seen_packet_ids : Map[@session.SessionPacketId, Bool] = Map([])
    for item in saved.inflight {
      let packet_id = match @session.SessionPacketId::new(item.packet_id) {
        Ok(value) => value
        Err(_) => return Err(InvalidPacketId(item.packet_id))
      }
      if seen_packet_ids.get(packet_id) is Some(_) {
        return Err(InvalidState("duplicate inflight packet id"))
      }
      seen_packet_ids.set(packet_id, true)
      if snapshot.version < 3 && item.phase != 1 {
        return Err(InvalidState("legacy snapshot contains QoS 2 phase"))
      }
      let phase : @session.OutboundPhase = match item.phase {
        1 => AwaitPuback
        2 => AwaitPubrec
        3 => AwaitPubcomp
        _ => return Err(InvalidState("unknown outbound phase"))
      }
      let message = match item.message {
        Some(message) => {
          if item.phase == 3 || message.qos != item.phase {
            return Err(InvalidState("inflight phase/message mismatch"))
          }
          match session_message_from_snapshot(message) {
            Ok(value) => Some(value)
            Err(error) => return Err(error)
          }
        }
        None => {
          if item.phase != 3 {
            return Err(InvalidState("missing inflight message"))
          }
          None
        }
      }
      restored_inflight.push({
        packet_id,
        delivery_id: 0L,
        started: true,
        subscription_identifiers: [],
        message,
        phase,
      })
    }
    let restored_pending : Array[@session.SessionMessage] = []
    for message in saved.pending {
      if snapshot.version < 3 && message.qos != 1 {
        return Err(InvalidQoS(message.qos))
      }
      match session_message_from_snapshot(message) {
        Ok(value) => restored_pending.push(value)
        Err(error) => return Err(error)
      }
    }
    if snapshot.version < 3 && !saved.inbound_qos2.is_empty() {
      return Err(InvalidState("legacy snapshot contains inbound QoS 2"))
    }
    if saved.inbound_qos2.length() > config.max_inbound_qos2_per_session() ||
      saved.inbound_qos2.length() >
      config.max_inbound_qos2_total() - total_inbound {
      return Err(LimitExceeded("inbound QoS 2 limit exceeded"))
    }
    total_inbound += saved.inbound_qos2.length()
    let inbound_qos2 : Array[@session.SessionPacketId] = []
    for value in saved.inbound_qos2 {
      let id = match @session.SessionPacketId::new(value) {
        Ok(id) => id
        Err(_) => return Err(InvalidPacketId(value))
      }
      if inbound_qos2.contains(id) {
        return Err(InvalidState("duplicate inbound packet id"))
      }
      inbound_qos2.push(id)
    }
    let session = match
      @session.ClientSession::restore(
        client_id,
        saved.next_packet_id,
        restored_inflight,
        restored_pending,
        owner~,
        inbound_qos2~,
        detached_at_ms=saved.detached_at_ms,
      ) {
      Ok(value) => value
      Err(@session.SessionError::InvalidPacketId(value)) =>
        return Err(InvalidPacketId(value))
      Err(_) => return Err(InvalidState("invalid restored session"))
    }
    state.track_policy_session(client_id)
    state.sessions.set(client_id, session)
    let seen_filters : Map[@topic.TopicFilter, Bool] = Map([])
    for subscription in saved.subscriptions {
      let filter = match @topic.TopicFilter::new(subscription.filter) {
        Ok(value) => value
        Err(_) => return Err(InvalidFilter(subscription.filter))
      }
      if seen_filters.get(filter) is Some(_) {
        return Err(DuplicateSubscription(saved.client_id, subscription.filter))
      }
      seen_filters.set(filter, true)
      if seen_filters.length() > config.max_subscriptions_per_session() ||
        state.subscriptions.subscription_count() >=
        config.max_subscriptions_total() {
        return Err(LimitExceeded("subscription limit exceeded"))
      }
      if snapshot.version < 3 && subscription.qos > 1 {
        return Err(InvalidQoS(subscription.qos))
      }
      let qos = match qos_from_snapshot(subscription.qos) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      ignore(state.subscriptions.put(client_id, filter, qos))
    }
  }
  let seen_retained : Map[@topic.TopicName, Bool] = Map([])
  for saved in snapshot.retained {
    let topic = match @topic.TopicName::new(saved.topic) {
      Ok(value) => value
      Err(_) => return Err(InvalidTopic(saved.topic))
    }
    if seen_retained.get(topic) is Some(_) {
      return Err(DuplicateRetained(saved.topic))
    }
    seen_retained.set(topic, true)
    if snapshot.version < 3 && saved.qos > 1 {
      return Err(InvalidQoS(saved.qos))
    }
    let qos = match qos_from_snapshot(saved.qos) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let cost = @budget.message_cost(
      saved.topic,
      saved.payload.length().to_int64(),
    ).unwrap()
    if cost - 96L > config.resources.get("max_retained_message_bytes") {
      return Err(LimitExceeded("retained message byte budget"))
    }
    match state.resources.set_retained(state.resources.retained_bytes + cost) {
      Err(_) => return Err(LimitExceeded("retained/global byte budget"))
      Ok(_) => ()
    }
    ignore(
      state.retained.put(
        topic,
        copy_router_bytes(saved.payload),
        qos,
        config.max_retained_messages(),
      ),
    )
  }
  state.inbound_qos2_total = total_inbound
  state.inflight_total = total_inflight
  state.pending_qos1_total = total_pending
  match state.check_invariants() {
    Ok(_) => Ok(state)
    Err(_) => Err(InvalidState("restored broker invariant failed"))
  }
}
