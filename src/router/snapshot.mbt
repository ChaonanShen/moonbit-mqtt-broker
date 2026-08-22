///|
pub(all) struct SnapshotSubscriptionV1 {
  filter : String
  qos : Int
} derive(Eq, Debug)

///|
pub(all) struct SnapshotMessageV1 {
  topic : String
  payload : Bytes
  retain : Bool
} derive(Eq, Debug)

///|
pub(all) struct SnapshotInflightV1 {
  packet_id : Int
  message : SnapshotMessageV1
} derive(Eq, Debug)

///|
pub(all) struct SnapshotSessionV1 {
  client_id : String
  next_packet_id : Int
  subscriptions : Array[SnapshotSubscriptionV1]
  inflight : Array[SnapshotInflightV1]
  pending : Array[SnapshotMessageV1]
} derive(Eq, Debug)

///|
pub(all) struct SnapshotRetainedV1 {
  topic : String
  payload : Bytes
  qos : Int
} derive(Eq, Debug)

///|
pub(all) struct BrokerSnapshotV1 {
  version : Int
  sessions : Array[SnapshotSessionV1]
  retained : Array[SnapshotRetainedV1]
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
  }
}

///|
fn qos_from_snapshot(
  value : Int,
) -> Result[@session.DeliveryQoS, SnapshotError] {
  match value {
    0 => Ok(QoS0)
    1 => Ok(QoS1)
    _ => Err(InvalidQoS(value))
  }
}

///|
fn snapshot_message(message : @session.SessionMessage) -> SnapshotMessageV1 {
  {
    topic: message.topic.value(),
    payload: copy_router_bytes(message.payload),
    retain: message.retain,
  }
}

///|
fn session_message_from_snapshot(
  message : SnapshotMessageV1,
) -> Result[@session.SessionMessage, SnapshotError] {
  let topic = match @topic.TopicName::new(message.topic) {
    Ok(value) => value
    Err(_) => return Err(InvalidTopic(message.topic))
  }
  Ok(
    @session.SessionMessage::new(
      topic,
      copy_router_bytes(message.payload),
      message.retain,
    ),
  )
}

///|
pub fn BrokerState::export_snapshot(self : BrokerState) -> BrokerSnapshotV1 {
  let client_ids : Array[@session.ClientId] = []
  for client_id, session in self.sessions {
    if session.mode() == @session.SessionMode::Persistent {
      client_ids.push(client_id)
    }
  }
  client_ids.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.value(), right.value())
  })
  let sessions : Array[SnapshotSessionV1] = []
  for client_id in client_ids {
    let session = self.sessions.get(client_id).unwrap()
    let subscriptions : Array[SnapshotSubscriptionV1] = []
    for record in self.subscriptions.records_for(client_id) {
      subscriptions.push({
        filter: record.filter.value(),
        qos: snapshot_qos(record.qos),
      })
    }
    let inflight = session
      .inflight()
      .map(item => {
        packet_id: item.packet_id.value(),
        message: snapshot_message(item.message),
      })
    let pending = session.pending().map(snapshot_message)
    sessions.push({
      client_id: client_id.value(),
      next_packet_id: session.next_packet_id(),
      subscriptions,
      inflight,
      pending,
    })
  }
  let retained : Array[SnapshotRetainedV1] = []
  for message in self.retained.all_messages() {
    retained.push({
      topic: message.topic.value(),
      payload: copy_router_bytes(message.payload),
      qos: snapshot_qos(message.qos),
    })
  }
  { version: 1, sessions, retained }
}

///|
pub fn BrokerState::from_snapshot(
  config : BrokerConfig,
  snapshot : BrokerSnapshotV1,
) -> Result[BrokerState, SnapshotError] {
  if snapshot.version != 1 {
    return Err(UnsupportedVersion(snapshot.version))
  }
  if snapshot.sessions.length() > config.max_sessions() {
    return Err(LimitExceeded("session limit exceeded"))
  }
  if snapshot.retained.length() > config.max_retained_messages() {
    return Err(LimitExceeded("retained limit exceeded"))
  }
  let state = BrokerState::new(config)
  let seen_sessions : Map[@session.ClientId, Bool] = Map([])
  let mut total_inflight = 0
  let mut total_pending = 0
  for saved in snapshot.sessions {
    let client_id = match @session.ClientId::new(saved.client_id) {
      Ok(value) => value
      Err(_) => return Err(InvalidClientId(saved.client_id))
    }
    if seen_sessions.get(client_id) is Some(_) {
      return Err(DuplicateSession(saved.client_id))
    }
    seen_sessions.set(client_id, true)
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
      let message = match session_message_from_snapshot(item.message) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      restored_inflight.push({ packet_id, message })
    }
    let restored_pending : Array[@session.SessionMessage] = []
    for message in saved.pending {
      match session_message_from_snapshot(message) {
        Ok(value) => restored_pending.push(value)
        Err(error) => return Err(error)
      }
    }
    let session = match
      @session.ClientSession::restore(
        client_id,
        saved.next_packet_id,
        restored_inflight,
        restored_pending,
      ) {
      Ok(value) => value
      Err(@session.SessionError::InvalidPacketId(value)) =>
        return Err(InvalidPacketId(value))
      Err(_) => return Err(InvalidState("invalid restored session"))
    }
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
    let qos = match qos_from_snapshot(saved.qos) {
      Ok(value) => value
      Err(error) => return Err(error)
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
  state.inflight_total = total_inflight
  state.pending_qos1_total = total_pending
  match state.check_invariants() {
    Ok(_) => Ok(state)
    Err(_) => Err(InvalidState("restored broker invariant failed"))
  }
}
