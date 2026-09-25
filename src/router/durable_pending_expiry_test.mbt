///|
test "C-T28 expired offline pending delivery is removed by V5 transaction" {
  let state = BrokerState::new(BrokerConfig::new(8, 16, 8).unwrap())
  state.enable_v5_storage()
  let client = @session.ClientId::new("pending-expiry").unwrap()
  let topic = @topic.TopicName::new("expiry/pending").unwrap()
  ignore(
    state
    .apply(
      CreateSessionWith({
        client_id: client,
        mode: @session.Persistent,
        attached: true,
      }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(
      SubscribeV5({
        client_id: client,
        entries: [
          {
            filter: @topic.TopicFilter::new("expiry/#").unwrap(),
            qos: @session.QoS1,
            no_local: false,
            retain_as_published: false,
            retain_handling: 0,
            subscription_identifier: Some(7),
          },
        ],
      }),
    )
    .unwrap(),
  )
  ignore(state.apply(DetachSession(client)).unwrap())
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
          payload: b"queued",
          qos: @session.QoS1,
          retain: false,
        },
        metadata,
      }),
    )
    .unwrap(),
  )
  assert_eq(state.pending_qos1_count(), 1)
  let before = state.export_snapshot_v5(now_mono_ms, 1000L).unwrap()
  assert_eq(before.sessions[0].pending.length(), 1)
  assert_eq(state.next_expired_pending(now_mono_ms), None)
  assert_eq(state.next_expired_pending(now_mono_ms + 1000L), Some((client, 0)))
  let plan = state
    .prepare_durable_pending_expiry(client, 0, now_mono_ms + 1000L)
    .unwrap()
  let delta = plan.delta_v5(now_mono_ms + 1000L, 2000L).unwrap()
  let accumulator = DurableAccumulatorV5::new(before)
  assert_eq(accumulator.apply(delta), Ok(()))
  assert_eq(accumulator.snapshot().sessions[0].pending.length(), 0)
  ignore(plan.commit().unwrap())
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}
