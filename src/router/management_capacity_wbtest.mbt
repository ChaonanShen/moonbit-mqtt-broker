///|
test "management index and delete at configured maximum object counts" {
  let config = BrokerConfig::new(16, 16384, 1024, max_sessions=1024).unwrap()
  let state = BrokerState::new(config)
  for session_number in 0..<1024 {
    let client_id = @session.ClientId::new(
      "capacity-" + session_number.to_string(),
    ).unwrap()
    ignore(
      state
      .apply(
        CreateSessionWith({
          client_id,
          mode: @session.Persistent,
          attached: false,
        }),
      )
      .unwrap(),
    )
    let entries : Array[SubscribeEntry] = []
    for filter_number in 0..<16 {
      entries.push({
        filter: @topic.TopicFilter::new(
          "f/" + session_number.to_string() + "/" + filter_number.to_string(),
        ).unwrap(),
        qos: @session.QoS1,
      })
    }
    ignore(state.apply(Subscribe({ client_id, entries })).unwrap())
  }
  for retained_number in 0..<1024 {
    ignore(
      state
      .apply(
        Publish({
          origin: PublishOrigin::Internal,
          topic: @topic.TopicName::new("r/" + retained_number.to_string()).unwrap(),
          payload: b"x",
          qos: @session.QoS0,
          retain: true,
        }),
      )
      .unwrap(),
    )
  }
  assert_eq(state.session_count(), 1024)
  assert_eq(state.subscription_count(), 16384)
  assert_eq(state.retained_count(), 1024)
  let indexed_at = @budget.monotonic_ms()
  assert_true(state.enable_management_index())
  let index_ms = @budget.monotonic_ms() - indexed_at
  let index = state.management_index().unwrap()
  assert_eq(index.live_count(), 1024)
  assert_eq(index.subscription_live_count(), 16384)
  assert_eq(index.retained_live_count(), 1024)
  let client_id = @session.ClientId::new("capacity-0").unwrap()
  let identity = index.identity_for_client(client_id).unwrap()
  let before = state.managed_bytes()
  let started = @budget.monotonic_ms()
  let actions = state
    .admin_delete_offline(identity.handle, identity.lifecycle_version)
    .unwrap()
  let elapsed = @budget.monotonic_ms() - started
  assert_true(actions.contains(SessionRemoved(client_id)))
  assert_eq(state.session_count(), 1023)
  assert_eq(state.subscription_count(), 16368)
  assert_eq(state.retained_count(), 1024)
  assert_true(state.managed_bytes() < before)
  assert_true(index.check_invariants())
  assert_eq(state.check_invariants(), Ok(()))
  println("B_CAPACITY_INDEX_MS=" + index_ms.to_string())
  println("B_CAPACITY_DELETE_MS=" + elapsed.to_string())
  println("B_CAPACITY_BEFORE_BYTES=" + before.to_string())
  println("B_CAPACITY_AFTER_BYTES=" + state.managed_bytes().to_string())
}
