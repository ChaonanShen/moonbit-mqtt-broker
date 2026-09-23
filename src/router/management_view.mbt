///|
pub(all) struct AdminSessionView {
  handle : Int64
  lifecycle_version : Int64
  client_id : String
  mode : String
  attached : Bool
  owner : String
  detached_at_ms : Int64?
  subscription_count : Int
  inflight_count : Int
  pending_count : Int
  inbound_qos2_count : Int
  inflight_bytes : Int64
  pending_bytes : Int64
  inbound_bytes : Int64
  subscription_bytes : Int64
} derive(Eq, Debug)

///|
pub(all) struct AdminSubscriptionView {
  filter : String
  qos : String
} derive(Eq, Debug)

///|
pub(all) struct AdminRetainedView {
  topic : String
  qos : String
  payload_bytes : Int64
} derive(Eq, Debug)

///|
fn admin_qos_name(qos : @session.DeliveryQoS) -> String {
  match qos {
    QoS0 => "0"
    QoS1 => "1"
    QoS2 => "2"
  }
}

///|
/// Reads only the requested live Session and existing counters. No
/// ClientSession.copy(), inflight()/pending() or payload export occurs.
pub fn BrokerState::admin_session_view(
  self : BrokerState,
  handle : Int64,
) -> AdminSessionView? {
  let index = match self.admin_sessions {
    Some(value) if value.available() => value
    _ => return None
  }
  let identity = match index.identity_for_handle(handle) {
    Some(value) => value
    None => return None
  }
  let session = match self.sessions.get(identity.client_id) {
    Some(value) => value
    None => return None
  }
  let usage = match self.resources.owners.get(identity.client_id) {
    Some(value) => value.usage
    None => return None
  }
  Some({
    handle,
    lifecycle_version: identity.lifecycle_version,
    client_id: identity.client_id.value(),
    mode: if session.mode() == @session.Persistent {
      "persistent"
    } else {
      "clean"
    },
    attached: session.is_attached(),
    owner: session.owner().storage_value(),
    detached_at_ms: session.detached_at_ms(),
    subscription_count: self.subscriptions.subscription_count_for(
      identity.client_id,
    ),
    inflight_count: session.inflight_count(),
    pending_count: session.pending_count(),
    inbound_qos2_count: session.inbound_qos2_count(),
    inflight_bytes: usage.inflight,
    pending_bytes: usage.pending,
    inbound_bytes: usage.inbound,
    subscription_bytes: usage.subscriptions,
  })
}

///|
pub fn BrokerState::admin_subscription_view(
  self : BrokerState,
  key : String,
) -> AdminSubscriptionView? {
  let index = match self.admin_sessions {
    Some(value) if value.available() => value
    _ => return None
  }
  let row = match index.subscription_row(key) {
    Some(value) => value
    None => return None
  }
  match self.subscriptions.qos(row.client_id, row.filter) {
    Some(qos) => Some({ filter: row.filter.value(), qos: admin_qos_name(qos) })
    None => None
  }
}

///|
pub fn BrokerState::admin_retained_view(
  self : BrokerState,
  topic_value : String,
) -> AdminRetainedView? {
  let index = match self.admin_sessions {
    Some(value) if value.available() => value
    _ => return None
  }
  if index.retained_slots.get(topic_value) is None {
    return None
  }
  let topic = match @topic.TopicName::new(topic_value) {
    Ok(value) => value
    Err(_) => return None
  }
  match self.retained.peek(topic) {
    Some(message) =>
      Some({
        topic: topic_value,
        qos: admin_qos_name(message.qos),
        payload_bytes: message.payload.length().to_int64(),
      })
    None => None
  }
}

///|
pub(all) enum AdminDeleteError {
  AdminDetailsUnavailable
  AdminNotFound
  AdminPreconditionFailed
  AdminSessionActive
  AdminInvariantViolation
} derive(Eq, Debug)

///|
/// The caller is the driver single writer and owns the action scope. No await
/// occurs between identity/lifecycle checks and BrokerState.apply.
pub fn BrokerState::admin_delete_offline(
  self : BrokerState,
  handle : Int64,
  expected_lifecycle_version : Int64,
) -> Result[Array[BrokerAction], AdminDeleteError] {
  let index = match self.admin_sessions {
    Some(value) if value.available() => value
    _ => return Err(AdminDetailsUnavailable)
  }
  let identity = match index.identity_for_handle(handle) {
    Some(value) => value
    None => return Err(AdminNotFound)
  }
  if identity.lifecycle_version != expected_lifecycle_version {
    return Err(AdminPreconditionFailed)
  }
  let session = match self.sessions.get(identity.client_id) {
    Some(value) => value
    None => return Err(AdminInvariantViolation)
  }
  if session.mode() != @session.Persistent || session.is_attached() {
    return Err(AdminSessionActive)
  }
  match self.apply(RemoveSession(identity.client_id)) {
    Ok(actions) => Ok(actions)
    Err(_) => Err(AdminInvariantViolation)
  }
}
