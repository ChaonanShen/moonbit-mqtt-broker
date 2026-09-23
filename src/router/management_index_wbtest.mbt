///|
fn managed_client(value : String) -> @session.ClientId {
  @session.ClientId::new(value).unwrap()
}

///|
fn managed_state() -> BrokerState {
  BrokerState::new(BrokerConfig::new(4, 16, 4, max_sessions=4).unwrap())
}

///|
fn managed_identity(
  state : BrokerState,
  client_id : @session.ClientId,
) -> AdminSessionIdentity {
  state.management_index().unwrap().identity_for_client(client_id).unwrap()
}

///|
test "session handle changes on replacement and re-creation" {
  let state = managed_state()
  assert_true(state.enable_management_index())
  let id = managed_client("same")
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
  let first = managed_identity(state, id)
  assert_eq(first.lifecycle_version, 1L)
  ignore(state.apply(RemoveSession(id)).unwrap())
  assert_true(
    state.management_index().unwrap().identity_for_handle(first.handle) is None,
  )
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
  let second = managed_identity(state, id)
  assert_true(second.handle > first.handle)
  let replacement = state
    .prepare_activation(id, @session.Clean, @security.Anonymous)
    .unwrap()
  ignore(state.commit_activation(replacement).unwrap())
  let third = managed_identity(state, id)
  assert_true(third.handle > second.handle)
  assert_true(state.management_index().unwrap().slots.check_invariants())
}

///|
test "persistent reattach and offline ABA bump lifecycle without new handle" {
  let state = managed_state()
  assert_true(state.enable_management_index())
  let id = managed_client("persistent")
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
  let first = managed_identity(state, id)
  ignore(state.apply(AttachSession(id)).unwrap())
  let second = managed_identity(state, id)
  assert_eq(second.handle, first.handle)
  assert_eq(second.lifecycle_version, first.lifecycle_version + 1L)
  ignore(state.apply(DetachSession(id)).unwrap())
  let third = managed_identity(state, id)
  assert_eq(third.handle, first.handle)
  assert_eq(third.lifecycle_version, first.lifecycle_version + 2L)
  let activation = state
    .prepare_activation(id, @session.Persistent, @security.Anonymous)
    .unwrap()
  assert_eq(managed_identity(state, id), third)
  ignore(state.commit_activation(activation).unwrap())
  let fourth = managed_identity(state, id)
  assert_eq(fourth.handle, first.handle)
  assert_eq(fourth.lifecycle_version, first.lifecycle_version + 3L)
}

///|
test "failed prepare and cancel do not publish a management instance" {
  let state = managed_state()
  assert_true(state.enable_management_index())
  let id = managed_client("cancelled")
  let pending = state
    .prepare_activation(id, @session.Persistent, @security.Anonymous)
    .unwrap()
  assert_true(state.management_index().unwrap().identity_for_client(id) is None)
  state.cancel_activation(pending).unwrap()
  assert_true(state.management_index().unwrap().identity_for_client(id) is None)
  let next = state
    .prepare_activation(id, @session.Persistent, @security.Anonymous)
    .unwrap()
  ignore(state.commit_activation(next).unwrap())
  assert_eq(managed_identity(state, id).lifecycle_version, 1L)
}

///|
test "snapshot restore initializes new derived index after restore" {
  let first = managed_state()
  let id = managed_client("restored")
  ignore(
    first
    .apply(
      CreateSessionWith({
        client_id: id,
        mode: @session.Persistent,
        attached: false,
      }),
    )
    .unwrap(),
  )
  assert_true(first.enable_management_index())
  let identity = managed_identity(first, id)
  assert_eq(identity.handle, 1L)
  let saved = first.export_snapshot()
  let second = BrokerState::from_snapshot(first.config(), saved).unwrap()
  assert_true(second.management_index() is None)
  assert_true(second.enable_management_index())
  assert_eq(managed_identity(second, id).lifecycle_version, 1L)
  assert_eq(second.management_index().unwrap().live_count(), 1)
}

///|
test "management index exhaustion fails closed without changing MQTT state" {
  let state = managed_state()
  assert_true(state.enable_management_index())
  let index = state.management_index().unwrap()
  index.next_handle = 9223372036854775807L
  let id = managed_client("still-works")
  ignore(state.apply(CreateSession(id)).unwrap())
  assert_true(state.has_session(id))
  assert_false(state.management_index_available())
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "subscription and retained metadata slots follow committed mutations" {
  let state = managed_state()
  let id = managed_client("metadata")
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
  let filter = @topic.TopicFilter::new("sensor/#").unwrap()
  let topic = @topic.TopicName::new("sensor/value").unwrap()
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
        payload: b"payload",
        qos: @session.QoS1,
        retain: true,
      }),
    )
    .unwrap(),
  )
  assert_true(state.enable_management_index())
  let index = state.management_index().unwrap()
  assert_eq(index.subscription_live_count(), 1)
  assert_eq(index.retained_live_count(), 1)
  assert_eq(index.subscription_page(id, 0, 256, 50).keys.length(), 1)
  assert_eq(index.retained_page(0, 256, 50).keys, ["sensor/value"])
  assert_true(index.check_invariants())
  ignore(
    state
    .apply(
      Publish({
        origin: PublishOrigin::Internal,
        topic,
        payload: b"new",
        qos: @session.QoS0,
        retain: true,
      }),
    )
    .unwrap(),
  )
  assert_eq(index.retained_live_count(), 1)
  ignore(
    state.apply(Unsubscribe({ client_id: id, filters: [filter] })).unwrap(),
  )
  assert_eq(index.subscription_live_count(), 0)
  ignore(
    state
    .apply(
      Publish({
        origin: PublishOrigin::Internal,
        topic,
        payload: b"",
        qos: @session.QoS0,
        retain: true,
      }),
    )
    .unwrap(),
  )
  assert_eq(index.retained_live_count(), 0)
  assert_true(index.check_invariants())
}

///|
test "successful subscribe and clean replacement clear metadata without payload copy" {
  let state = managed_state()
  assert_true(state.enable_management_index())
  let id = managed_client("replace")
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
  let filter = @topic.TopicFilter::new("a/#").unwrap()
  ignore(
    state
    .apply(
      Subscribe({ client_id: id, entries: [{ filter, qos: @session.QoS1 }] }),
    )
    .unwrap(),
  )
  let index = state.management_index().unwrap()
  assert_eq(index.subscription_live_count(), 1)
  let previous = managed_identity(state, id)
  let replacement = state
    .prepare_activation(id, @session.Clean, @security.Anonymous)
    .unwrap()
  ignore(state.commit_activation(replacement).unwrap())
  assert_eq(index.subscription_live_count(), 0)
  assert_true(managed_identity(state, id).handle != previous.handle)
  assert_true(index.check_invariants())
}

///|
test "metadata view reads counts and payload length without exporting payload" {
  let state = managed_state()
  assert_true(state.enable_management_index())
  let id = managed_client("large")
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
  let topic = @topic.TopicName::new("large/topic").unwrap()
  let filter = @topic.TopicFilter::new("large/#").unwrap()
  ignore(
    state
    .apply(
      Subscribe({ client_id: id, entries: [{ filter, qos: @session.QoS1 }] }),
    )
    .unwrap(),
  )
  let payload = Bytes::make(4096, 65)
  ignore(
    state
    .apply(
      Publish({
        origin: PublishOrigin::Internal,
        topic,
        payload,
        qos: @session.QoS1,
        retain: true,
      }),
    )
    .unwrap(),
  )
  let index = state.management_index().unwrap()
  let identity = managed_identity(state, id)
  let session = state.admin_session_view(identity.handle).unwrap()
  assert_eq(session.client_id, "large")
  assert_eq(session.pending_count, 1)
  assert_eq(session.subscription_count, 1)
  assert_true(session.pending_bytes > 4096L)
  let subkey = index.subscription_page(id, 0, 256, 50).keys[0]
  assert_eq(state.admin_subscription_view(subkey).unwrap().filter, "large/#")
  let retained = state.admin_retained_view("large/topic").unwrap()
  assert_eq(retained.payload_bytes, 4096L)
  assert_eq(retained.topic, "large/topic")
}

///|
test "delivery copy and ACK preserve management handle and lifecycle" {
  let state = managed_state()
  assert_true(state.enable_management_index())
  let id = managed_client("copy-stable")
  ignore(
    state
    .apply(
      CreateSessionWith({
        client_id: id,
        mode: @session.Persistent,
        attached: true,
      }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(
      Subscribe({
        client_id: id,
        entries: [
          {
            filter: @topic.TopicFilter::new("copy/topic").unwrap(),
            qos: @session.QoS1,
          },
        ],
      }),
    )
    .unwrap(),
  )
  let initial = managed_identity(state, id)
  let actions = state
    .apply(
      Publish({
        origin: PublishOrigin::Internal,
        topic: @topic.TopicName::new("copy/topic").unwrap(),
        payload: b"copy",
        qos: @session.QoS1,
        retain: false,
      }),
    )
    .unwrap()
  let packet_id = match actions[0] {
    Deliver(value) => value.packet_id.unwrap()
    _ => fail("expected inflight delivery")
  }
  assert_eq(managed_identity(state, id), initial)
  ignore(state.apply(Puback({ client_id: id, packet_id })).unwrap())
  assert_eq(managed_identity(state, id), initial)
  assert_eq(state.management_index().unwrap().live_count(), 1)
}
