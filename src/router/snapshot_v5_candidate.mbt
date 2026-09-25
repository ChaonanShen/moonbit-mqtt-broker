///|
pub fn BrokerState::snapshot_session_v5_candidate(
  self : BrokerState,
  client_id : @session.ClientId,
  session : @session.ClientSession,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  bindings? : Array[SubscriptionBinding] = self.subscriptions.bindings_for(
    client_id,
  ),
  incarnation? : Int64 = self.session_incarnation(client_id).unwrap_or(0L),
) -> Result[SnapshotSessionV5, SnapshotError] {
  let subscriptions : Array[SnapshotSubscriptionV5] = []
  for binding in bindings {
    subscriptions.push({
      identity: binding.identity,
      kind: if binding.filter.value().has_prefix("$share/") {
        2
      } else {
        0
      },
      wire_filter: binding.filter.value(),
      group_id: None,
      group_incarnation: None,
      inner_filter: None,
      qos: snapshot_qos(binding.qos),
      no_local: binding.no_local,
      retain_as_published: binding.retain_as_published,
      retain_handling: binding.retain_handling,
      subscription_identifier: binding.subscription_identifier.map(id => {
        id.reinterpret_as_uint()
      }),
    })
  }
  let inbound_qos2 : Array[SnapshotInboundQoS2V5] = session
    .inbound_qos2()
    .map(id => { packet_id: id.value(), success_reason: 0 })
  let inflight : Array[SnapshotInflightV5] = []
  for item in session.inflight() {
    if item.delivery_id < 1L {
      return Err(InvalidState("missing durable delivery identity"))
    }
    let message = match item.message {
      None => None
      Some(value) =>
        match v5_snapshot_message(value, now_mono_ms, now_wall_ms) {
          Ok(value) => Some(value)
          Err(error) => return Err(error)
        }
    }
    inflight.push({
      packet_id: item.packet_id.value(),
      delivery_id: item.delivery_id,
      phase: match item.phase {
        AwaitPuback => 1
        AwaitPubrec => 2
        AwaitPubcomp => 3
      },
      started: item.started,
      message,
      shared_origin: None,
      subscription_identifiers: item.subscription_identifiers.map(id => {
        id.reinterpret_as_uint()
      }),
    })
  }
  let pending : Array[SnapshotPendingV5] = []
  for item in session.pending() {
    if item.delivery_id < 1L {
      return Err(InvalidState("missing durable pending identity"))
    }
    let message = match v5_snapshot_message(item, now_mono_ms, now_wall_ms) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    pending.push({
      delivery_id: item.delivery_id,
      message,
      shared_origin: None,
      subscription_identifiers: item.subscription_identifiers.map(id => {
        id.reinterpret_as_uint()
      }),
    })
  }
  let session_expiry_clock = match session.expiry_deadline() {
    None => None
    Some(value) =>
      match v5_snapshot_clock(value, now_mono_ms, now_wall_ms) {
        Ok(clock) => Some(clock)
        Err(error) => return Err(error)
      }
  }
  if incarnation < 1L {
    return Err(InvalidState("missing Session incarnation"))
  }
  Ok({
    client_id: client_id.value(),
    owner_principal: session.owner().storage_value(),
    incarnation,
    lifecycle_version: 1L,
    state_revision: session.policy_revision(),
    last_protocol: session.last_protocol(),
    retention: session.retention(),
    attached_at_capture: session.is_attached(),
    detached_at_wall_ms: session.detached_at_ms(),
    session_expiry_clock,
    next_packet_id: session.next_packet_id(),
    subscriptions,
    inbound_qos2,
    inflight,
    pending,
  })
}

///|
fn BrokerState::session_put_v5(
  self : BrokerState,
  client_id : @session.ClientId,
  candidate : @session.ClientSession,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
  bindings? : Array[SubscriptionBinding] = self.subscriptions.bindings_for(
    client_id,
  ),
  proposed_incarnation? : Int64 = self
    .session_incarnation(client_id)
    .unwrap_or(0L),
) -> Result[Mqtt5SessionPut, RouterError] {
  let original = self.sessions.get(client_id)
  let session = match
    self.snapshot_session_v5_candidate(
      client_id,
      candidate,
      now_mono_ms,
      now_wall_ms,
      bindings~,
      incarnation=proposed_incarnation,
    ) {
    Ok(value) => value
    Err(_) =>
      return Err(InvariantViolation("cannot export V5 candidate Session"))
  }
  Ok({
    expected_incarnation: original
    .map(_ => self.session_incarnation(client_id).unwrap())
    .unwrap_or(0L),
    expected_revision: original
    .map(value => value.policy_revision())
    .unwrap_or(0L),
    session,
  })
}
