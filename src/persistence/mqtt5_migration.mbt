///|
fn v3_empty_properties() -> @router.SnapshotApplicationPropertiesV5 {
  {
    payload_format: None,
    content_type: None,
    response_topic: None,
    correlation_data: None,
    user_properties: [],
  }
}

///|
fn v3_message_to_v5(
  message : @router.SnapshotMessageV3,
) -> @router.SnapshotMessageV5 {
  {
    topic: message.topic,
    payload: Bytes::from_array(message.payload.to_array()),
    qos: message.qos,
    retain: message.retain,
    publisher_client_id: None,
    properties: v3_empty_properties(),
    expiry_clock: None,
  }
}

///|
pub fn convert_v3_snapshot_to_v5(
  old : @router.BrokerSnapshotV3,
) -> Result[@router.BrokerSnapshotV5, PersistenceError] {
  if old.version < 1 || old.version > 3 {
    return Err(UnsupportedEnvelopeVersion(old.version))
  }
  let sessions = old.sessions.copy()
  sessions.sort_by(fn(left, right) {
    if left.client_id < right.client_id {
      -1
    } else if left.client_id > right.client_id {
      1
    } else {
      0
    }
  })
  let mut next_session_incarnation = 1L
  let mut next_subscription_identity = 1L
  let mut next_delivery_id = 1L
  let upgraded_sessions : Array[@router.SnapshotSessionV5] = []
  let seen_sessions : Map[String, Bool] = Map([])
  for session in sessions {
    if seen_sessions.contains(session.client_id) || session.client_id == "" {
      return Err(SnapshotImport("duplicate or empty legacy client id"))
    }
    seen_sessions.set(session.client_id, true)
    let subscriptions : Array[@router.SnapshotSubscriptionV5] = []
    for item in session.subscriptions {
      subscriptions.push({
        identity: next_subscription_identity,
        kind: if item.filter.has_prefix("$share/") {
          2
        } else {
          0
        },
        wire_filter: item.filter,
        group_id: None,
        group_incarnation: None,
        inner_filter: None,
        qos: item.qos,
        no_local: false,
        retain_as_published: false,
        retain_handling: 0,
        subscription_identifier: None,
      })
      next_subscription_identity += 1L
    }
    let inbound_qos2 : Array[@router.SnapshotInboundQoS2V5] = session.inbound_qos2.map(packet_id => {
        packet_id,
        success_reason: 0,
      },
    )
    let inflight : Array[@router.SnapshotInflightV5] = []
    for item in session.inflight {
      inflight.push({
        packet_id: item.packet_id,
        delivery_id: next_delivery_id,
        phase: item.phase,
        started: true,
        message: item.message.map(v3_message_to_v5),
        shared_origin: None,
        subscription_identifiers: [],
      })
      next_delivery_id += 1L
    }
    let pending : Array[@router.SnapshotPendingV5] = []
    for item in session.pending {
      pending.push({
        delivery_id: next_delivery_id,
        message: v3_message_to_v5(item),
        shared_origin: None,
        subscription_identifiers: [],
      })
      next_delivery_id += 1L
    }
    upgraded_sessions.push({
      client_id: session.client_id,
      owner_principal: session.owner_principal,
      incarnation: next_session_incarnation,
      lifecycle_version: 1L,
      state_revision: 1L,
      last_protocol: 4,
      retention: @session.LegacyBrokerPolicy,
      attached_at_capture: false,
      detached_at_wall_ms: Some(session.detached_at_ms),
      session_expiry_clock: None,
      next_packet_id: session.next_packet_id,
      subscriptions,
      inbound_qos2,
      inflight,
      pending,
    })
    next_session_incarnation += 1L
  }
  let retained = old.retained.copy()
  retained.sort_by(fn(left, right) {
    if left.topic < right.topic {
      -1
    } else if left.topic > right.topic {
      1
    } else {
      0
    }
  })
  let upgraded_retained : Array[@router.SnapshotRetainedV5] = []
  let mut next_retained_revision = 1L
  for item in retained {
    upgraded_retained.push({
      revision: next_retained_revision,
      message: {
        topic: item.topic,
        payload: Bytes::from_array(item.payload.to_array()),
        qos: item.qos,
        retain: true,
        publisher_client_id: None,
        properties: v3_empty_properties(),
        expiry_clock: None,
      },
    })
    next_retained_revision += 1L
  }
  let snapshot : @router.BrokerSnapshotV5 = {
    clock_floor_wall_ms: 0L,
    next_session_incarnation,
    next_subscription_identity,
    next_delivery_id,
    next_group_id: 1L,
    next_will_id: 1L,
    next_retained_revision,
    groups: [],
    sessions: upgraded_sessions,
    retained: upgraded_retained,
    wills: [],
  }
  match encode_snapshot_v5(snapshot) {
    Ok(_) => Ok(snapshot)
    Err(error) => Err(error)
  }
}
