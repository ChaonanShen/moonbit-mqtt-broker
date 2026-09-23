///|
test "guarded offline delete rechecks lifecycle and preserves retained data" {
  let state = BrokerState::new(
    BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap(),
  )
  assert_true(state.enable_management_index())
  let id = @session.ClientId::new("offline-delete").unwrap()
  ignore(
    state
    .apply(
      CreateSessionWith({
        client_id: id,
        mode: @session.Persistent,
        attached: false,
      }),
    )
    .unwrap(),
  )
  let filter = @topic.TopicFilter::new("delete/#").unwrap()
  let topic = @topic.TopicName::new("delete/topic").unwrap()
  ignore(
    state
    .apply(
      Subscribe({ client_id: id, entries: [{ filter, qos: @session.QoS1 }] }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(
      Publish({
        origin: PublishOrigin::Internal,
        topic,
        payload: b"pending",
        qos: @session.QoS1,
        retain: true,
      }),
    )
    .unwrap(),
  )
  let identity = state
    .management_index()
    .unwrap()
    .identity_for_client(id)
    .unwrap()
  assert_eq(state.pending_qos1_count(), 1)
  assert_eq(state.subscription_count(), 1)
  assert_true(
    state.admin_delete_offline(identity.handle, 2L)
    is Err(AdminPreconditionFailed),
  )
  let actions = state.admin_delete_offline(identity.handle, 1L).unwrap()
  assert_true(actions.contains(SessionRemoved(id)))
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(state.subscription_count(), 0)
  assert_eq(state.retained_count(), 1)
  assert_true(
    state.admin_delete_offline(identity.handle, 1L) is Err(AdminNotFound),
  )
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "guarded delete refuses active and stale offline ABA instances" {
  let state = BrokerState::new(
    BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap(),
  )
  assert_true(state.enable_management_index())
  let id = @session.ClientId::new("aba").unwrap()
  ignore(
    state
    .apply(
      CreateSessionWith({
        client_id: id,
        mode: @session.Persistent,
        attached: false,
      }),
    )
    .unwrap(),
  )
  let identity = state
    .management_index()
    .unwrap()
    .identity_for_client(id)
    .unwrap()
  ignore(state.apply(AttachSession(id)).unwrap())
  assert_true(
    state.admin_delete_offline(identity.handle, 1L)
    is Err(AdminPreconditionFailed),
  )
  let online = state
    .management_index()
    .unwrap()
    .identity_for_client(id)
    .unwrap()
  assert_true(
    state.admin_delete_offline(identity.handle, online.lifecycle_version)
    is Err(AdminSessionActive),
  )
  ignore(state.apply(DetachSession(id)).unwrap())
  assert_true(
    state.admin_delete_offline(identity.handle, 1L)
    is Err(AdminPreconditionFailed),
  )
  assert_true(state.has_session(id))
}

///|
test "offline delete releases inbound QoS2 and AwaitPubcomp metadata" {
  let state = BrokerState::new(BrokerConfig::new(4, 16, 4).unwrap())
  assert_true(state.enable_management_index())
  let client_id = @session.ClientId::new("qos2-delete").unwrap()
  ignore(
    state
    .apply(
      CreateSessionWith({ client_id, mode: @session.Persistent, attached: true }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(
      Subscribe({
        client_id,
        entries: [
          {
            filter: @topic.TopicFilter::new("qos2/delete").unwrap(),
            qos: @session.QoS2,
          },
        ],
      }),
    )
    .unwrap(),
  )
  let deliveries = state
    .apply(
      Publish({
        origin: PublishOrigin::Internal,
        topic: @topic.TopicName::new("qos2/delete").unwrap(),
        payload: b"outbound",
        qos: @session.QoS2,
        retain: false,
      }),
    )
    .unwrap()
  let packet_id = match deliveries[0] {
    Deliver(value) => value.packet_id.unwrap()
    _ => fail("expected QoS2 delivery")
  }
  ignore(state.apply(Pubrec({ client_id, packet_id })).unwrap())
  ignore(
    state
    .apply(
      ReceiveQoS2({
        client_id,
        packet_id: @session.SessionPacketId::new(99).unwrap(),
        publish: None,
      }),
    )
    .unwrap(),
  )
  assert_eq(state.inflight_count(), 1)
  assert_eq(state.inbound_qos2_count(), 1)
  ignore(state.apply(DetachSession(client_id)).unwrap())
  let identity = state
    .management_index()
    .unwrap()
    .identity_for_client(client_id)
    .unwrap()
  ignore(
    state
    .admin_delete_offline(identity.handle, identity.lifecycle_version)
    .unwrap(),
  )
  assert_eq(state.inflight_count(), 0)
  assert_eq(state.inbound_qos2_count(), 0)
  assert_eq(state.subscription_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}
