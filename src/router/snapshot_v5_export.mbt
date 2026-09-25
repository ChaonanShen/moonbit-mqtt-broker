///|
fn v5_snapshot_clock(
  deadline : @session.Deadline,
  now_mono_ms : Int64,
  effective_wall_ms : Int64,
) -> Result[SnapshotClockV5, SnapshotError] {
  let remaining_ms = deadline.remaining_at(now_mono_ms)
  let deadline_wall_ms = match
    @budget.checked_add(effective_wall_ms, remaining_ms) {
    Ok(value) => value
    Err(_) => return Err(InvalidState("V5 snapshot clock overflow"))
  }
  Ok({ sample_wall_ms: effective_wall_ms, remaining_ms, deadline_wall_ms })
}

///|
fn v5_snapshot_message(
  message : @session.SessionMessage,
  now_mono_ms : Int64,
  effective_wall_ms : Int64,
) -> Result[SnapshotMessageV5, SnapshotError] {
  let meta = message.metadata
  let expiry_clock = match meta.expiry {
    None => None
    Some(deadline) =>
      match v5_snapshot_clock(deadline, now_mono_ms, effective_wall_ms) {
        Ok(value) => Some(value)
        Err(error) => return Err(error)
      }
  }
  Ok({
    topic: message.topic.value(),
    payload: copy_router_bytes(message.payload),
    qos: snapshot_qos(message.qos),
    retain: message.retain,
    publisher_client_id: meta.publisher_client_id.map(id => id.value()),
    properties: {
      payload_format: meta.payload_format,
      content_type: meta.content_type,
      response_topic: meta.response_topic.map(topic => topic.value()),
      correlation_data: meta.correlation_data.map(copy_router_bytes),
      user_properties: meta.user_properties.copy(),
    },
    expiry_clock,
  })
}

///|
pub fn BrokerState::export_snapshot_v5(
  self : BrokerState,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[BrokerSnapshotV5, SnapshotError] {
  if now_mono_ms < 0L || now_wall_ms < 0L {
    return Err(InvalidState("negative V5 snapshot clock"))
  }
  if now_wall_ms > self.clock_floor_wall_ms {
    self.clock_floor_wall_ms = now_wall_ms
  }
  let effective_wall = self.clock_floor_wall_ms
  let session_ids = self.sessions.keys().collect()
  session_ids.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.value(), right.value())
  })
  let mut next_session_incarnation = 1L
  let mut next_delivery_id = self.next_delivery_id
  let sessions : Array[SnapshotSessionV5] = []
  for client_id in session_ids {
    let session = self.sessions.get(client_id).unwrap()
    if session.mode() != @session.Persistent {
      continue
    }
    let subscriptions : Array[SnapshotSubscriptionV5] = []
    for binding in self.subscriptions.bindings_for(client_id) {
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
      let delivery_id = if item.delivery_id > 0L {
        item.delivery_id
      } else {
        let assigned = next_delivery_id
        next_delivery_id += 1L
        assigned
      }
      if delivery_id >= next_delivery_id {
        next_delivery_id = delivery_id + 1L
      }
      let message = match item.message {
        None => None
        Some(value) =>
          match v5_snapshot_message(value, now_mono_ms, effective_wall) {
            Ok(result) => Some(result)
            Err(error) => return Err(error)
          }
      }
      inflight.push({
        packet_id: item.packet_id.value(),
        delivery_id,
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
      let delivery_id = if item.delivery_id > 0L {
        item.delivery_id
      } else {
        let assigned = next_delivery_id
        next_delivery_id += 1L
        assigned
      }
      if delivery_id >= next_delivery_id {
        next_delivery_id = delivery_id + 1L
      }
      let message = match
        v5_snapshot_message(item, now_mono_ms, effective_wall) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      pending.push({
        delivery_id,
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
        match v5_snapshot_clock(value, now_mono_ms, effective_wall) {
          Ok(result) => Some(result)
          Err(error) => return Err(error)
        }
    }
    sessions.push({
      client_id: client_id.value(),
      owner_principal: session.owner().storage_value(),
      incarnation: next_session_incarnation,
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
    next_session_incarnation += 1L
  }
  let retained : Array[SnapshotRetainedV5] = []
  for message in self.retained.all_messages() {
    let meta = message.metadata
    let expiry_clock = match meta.expiry {
      None => None
      Some(value) =>
        match v5_snapshot_clock(value, now_mono_ms, effective_wall) {
          Ok(result) => Some(result)
          Err(error) => return Err(error)
        }
    }
    retained.push({
      revision: self.retained.revision(message.topic).unwrap(),
      message: {
        topic: message.topic.value(),
        payload: copy_router_bytes(message.payload),
        qos: snapshot_qos(message.qos),
        retain: true,
        publisher_client_id: meta.publisher_client_id.map(id => id.value()),
        properties: {
          payload_format: meta.payload_format,
          content_type: meta.content_type,
          response_topic: meta.response_topic.map(topic => topic.value()),
          correlation_data: meta.correlation_data.map(copy_router_bytes),
          user_properties: meta.user_properties.copy(),
        },
        expiry_clock,
      },
    })
  }
  Ok({
    clock_floor_wall_ms: effective_wall,
    next_session_incarnation,
    next_subscription_identity: self.subscriptions.next_identity(),
    next_delivery_id,
    next_group_id: 1L,
    next_will_id: 1L,
    next_retained_revision: self.retained.next_revision(),
    groups: [],
    sessions,
    retained,
    wills: [],
  })
}
