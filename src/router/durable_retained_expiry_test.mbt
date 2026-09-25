///|
test "C-T28 expired retained deletion is a revision checked V5 transaction" {
  let state = BrokerState::new(BrokerConfig::new(8, 16, 8).unwrap())
  let topic = @topic.TopicName::new("expiry/retained").unwrap()
  let now_mono_ms = @budget.monotonic_ms()
  let metadata : @session.MessageMetadata = {
    ..@session.MessageMetadata::empty(),
    expiry: Some(@session.Deadline::new(now_mono_ms, 1000L, 1000L).unwrap()),
  }
  ignore(
    state
    .apply(
      PublishV5({
        publish: {
          origin: Internal,
          topic,
          payload: b"short-lived",
          qos: @session.QoS1,
          retain: true,
        },
        metadata,
      }),
    )
    .unwrap(),
  )
  let before = state.export_snapshot_v5(now_mono_ms, 1000L).unwrap()
  assert_eq(before.retained.length(), 1)
  assert_eq(state.next_expired_retained(now_mono_ms), None)
  assert_eq(state.next_expired_retained(now_mono_ms + 1000L), Some(topic))
  let plan = state
    .prepare_durable_retained_expiry(topic, now_mono_ms + 1000L)
    .unwrap()
  let delta = plan.delta_v5(now_mono_ms + 1000L, 2000L).unwrap()
  let accumulator = DurableAccumulatorV5::new(before)
  assert_eq(accumulator.apply(delta), Ok(()))
  assert_eq(accumulator.snapshot().retained.length(), 0)
  ignore(plan.commit().unwrap())
  assert_eq(state.retained_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "C-T10 retained expiry replacement and deletion cancel prior timer" {
  let state = BrokerState::new(BrokerConfig::new(8, 16, 8).unwrap())
  let topic = @topic.TopicName::new("expiry/replacement").unwrap()
  let base = @budget.monotonic_ms()
  let first : @session.MessageMetadata = {
    ..@session.MessageMetadata::empty(),
    expiry: Some(@session.Deadline::new(base, 1000L, 1000L).unwrap()),
  }
  let second : @session.MessageMetadata = {
    ..@session.MessageMetadata::empty(),
    expiry: Some(@session.Deadline::new(base, 1000L, 4000L).unwrap()),
  }
  for value in [first, second] {
    ignore(
      state
      .apply(
        PublishV5({
          publish: {
            origin: Internal,
            topic,
            payload: b"live",
            qos: @session.QoS1,
            retain: true,
          },
          metadata: value,
        }),
      )
      .unwrap(),
    )
  }
  assert_eq(state.next_expired_retained(base + 1000L), None)
  assert_eq(state.next_expired_retained(base + 4000L), Some(topic))
  ignore(
    state
    .apply(
      PublishV5({
        publish: {
          origin: Internal,
          topic,
          payload: b"",
          qos: @session.QoS1,
          retain: true,
        },
        metadata: @session.MessageMetadata::empty(),
      }),
    )
    .unwrap(),
  )
  assert_eq(state.next_expired_retained(base + 5000L), None)
  assert_eq(state.check_invariants(), Ok(()))
}
