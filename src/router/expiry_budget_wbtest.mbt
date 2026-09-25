///|
test "C-T28 global expiry budget combines independent indexed classes" {
  let state = BrokerState::new(BrokerConfig::new(8, 16, 8).unwrap())
  let client = @session.ClientId::new("indexed-session").unwrap()
  let activation = state
    .prepare_activation(
      client,
      @session.Persistent,
      @security.Anonymous,
      v5_retention=@session.FiniteV5(10U),
      now_mono_ms=1000L,
    )
    .unwrap()
  ignore(state.commit_activation(activation).unwrap())
  ignore(
    state
    .apply(
      DetachSessionV5({
        client_id: client,
        now_mono_ms: 1000L,
        now_wall_ms: 10000L,
      }),
    )
    .unwrap(),
  )
  let topic = @topic.TopicName::new("indexed/retained").unwrap()
  let now_mono_ms = @budget.monotonic_ms()
  let metadata : @session.MessageMetadata = {
    ..@session.MessageMetadata::empty(),
    expiry: Some(@session.Deadline::new(now_mono_ms, 1000L, 10000L).unwrap()),
  }
  ignore(
    state
    .apply(
      PublishV5({
        publish: {
          origin: Internal,
          topic,
          payload: b"value",
          qos: @session.QoS1,
          retain: true,
        },
        metadata,
      }),
    )
    .unwrap(),
  )
  let used = state.expiry_index_bytes()
  assert_true(used > state.session_expiry.used_bytes())
  assert_true(used > state.retained.expiry_index_bytes())
  assert_true(state.expiry_index_fits(8388608L - used))
  assert_false(state.expiry_index_fits(8388609L - used))
  assert_eq(state.check_invariants(), Ok(()))
}
