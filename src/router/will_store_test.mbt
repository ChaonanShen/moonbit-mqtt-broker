///|
test "C-T32 MQTT5 delayed Will waits and publishes once" {
  let state = BrokerState::new(BrokerConfig::new(8, 16, 8).unwrap())
  let source = @session.ClientId::new("will-source").unwrap()
  let target = @session.ClientId::new("will-target").unwrap()
  ignore(state.apply(CreateSession(source)))
  ignore(state.apply(CreateSession(target)))
  ignore(
    state.apply(
      Subscribe({
        client_id: target,
        entries: [
          {
            filter: @topic.TopicFilter::new("status/#").unwrap(),
            qos: @session.QoS1,
          },
        ],
      }),
    ),
  )
  let template : Mqtt5WillTemplate = {
    topic: @topic.TopicName::new("status/source").unwrap(),
    payload: b"offline",
    qos: @session.QoS1,
    retain: false,
    metadata: @session.MessageMetadata::empty(),
    delay_seconds: 2U,
    message_expiry_seconds: Some(5U),
  }
  let prepared = state
    .prepare_mqtt5_will(source, @security.Anonymous, template, 4, 0L)
    .unwrap()
  let id = state.commit_prepared_will(prepared)
  assert_eq(state.will_count(), 1)
  assert_true(state.trigger_will(id, 1000L, 10000L, @session.InfiniteV5))
  assert_eq(state.next_due_will(2999L), None)
  assert_eq(state.next_due_will(3000L), Some(id))
  assert_eq(
    state.cancel_wills_for_session(
      source,
      state.session_incarnation(source).unwrap(),
      now_mono_ms=3000L,
    ),
    0,
  )
  let actions = state.publish_due_will(id, 3000L, 12000L).unwrap()
  assert_true(actions.any(action => action is DeliverWithMetadata(_)))
  assert_eq(state.will_count(), 0)
  assert_eq(state.next_due_will(4000L), None)
}

///|
test "C-T36 V5 pending Will restart keeps original deadline" {
  let config = BrokerConfig::new(8, 16, 8).unwrap()
  let state = BrokerState::new(config)
  let source = @session.ClientId::new("will-restart").unwrap()
  let activation = state
    .prepare_activation(
      source,
      @session.Persistent,
      @security.Anonymous,
      v5_resume=false,
      v5_retention=@session.FiniteV5(10U),
      now_mono_ms=100L,
    )
    .unwrap()
  ignore(state.commit_activation(activation).unwrap())
  let template : Mqtt5WillTemplate = {
    topic: @topic.TopicName::new("will/restart").unwrap(),
    payload: b"offline",
    qos: @session.QoS1,
    retain: true,
    metadata: @session.MessageMetadata::empty(),
    delay_seconds: 2U,
    message_expiry_seconds: Some(5U),
  }
  let prepared = state
    .prepare_mqtt5_will(source, @security.Anonymous, template, 4, 0L)
    .unwrap()
  let id = state.commit_prepared_will(prepared)
  assert_true(state.trigger_will(id, 1000L, 10000L, @session.FiniteV5(10U)))
  let snapshot = state.export_snapshot_v5(1000L, 10000L).unwrap()
  assert_eq(snapshot.wills.length(), 1)
  let restored = BrokerState::from_snapshot_v5(config, snapshot, 1500L, 10500L).unwrap()
  assert_eq(restored.next_due_will(2999L), None)
  assert_eq(restored.next_due_will(3000L), Some(id))
  assert_eq(
    restored.export_snapshot_v5(1500L, 10500L).unwrap().wills[0].due_clock.unwrap().remaining_ms,
    1500L,
  )
}

///|
test "C-T32 Will expiry index removes cancelled pending identity" {
  let state = BrokerState::new(BrokerConfig::new(8, 16, 8).unwrap())
  let client = @session.ClientId::new("will-index-cancel").unwrap()
  ignore(state.apply(CreateSession(client)))
  let template : Mqtt5WillTemplate = {
    topic: @topic.TopicName::new("will/index").unwrap(),
    payload: b"offline",
    qos: @session.QoS1,
    retain: false,
    metadata: @session.MessageMetadata::empty(),
    delay_seconds: 1U,
    message_expiry_seconds: None,
  }
  let prepared = state
    .prepare_mqtt5_will(client, @security.Anonymous, template, 4, 0L)
    .unwrap()
  let id = state.commit_prepared_will(prepared)
  assert_true(state.trigger_will(id, 1000L, 1000L, @session.InfiniteV5))
  assert_eq(state.next_due_will(2000L), Some(id))
  assert_true(state.cancel_will(id))
  assert_eq(state.next_due_will(3000L), None)
  assert_eq(state.check_invariants(), Ok(()))
}
