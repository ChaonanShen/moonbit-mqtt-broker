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
