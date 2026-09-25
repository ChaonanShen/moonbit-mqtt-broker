///|
test "C-T34 resource-limited MQTT5 Will stays pending for bounded retry" {
  let broker_config = @router.BrokerConfig::new(8, 16, 0).unwrap()
  let config = ServerConfig::new(
    128,
    1048576,
    1048576,
    64,
    512,
    10000,
    100,
    broker_config,
    protocol_config=@config.ProtocolConfig::new(mqtt5_enabled=true).unwrap(),
  ).unwrap()
  let state = @router.BrokerState::new(broker_config)
  let client = @session.ClientId::new("will-retry").unwrap()
  ignore(state.apply(@router.CreateSession(client)).unwrap())
  let template : @router.Mqtt5WillTemplate = {
    topic: @topic.TopicName::new("will/retry").unwrap(),
    payload: b"offline",
    qos: @session.QoS1,
    retain: true,
    metadata: @session.MessageMetadata::empty(),
    delay_seconds: 0U,
    message_expiry_seconds: None,
  }
  let prepared = state
    .prepare_mqtt5_will(client, @security.Anonymous, template, 4, 0L)
    .unwrap()
  let will_id = state.commit_prepared_will(prepared)
  let now_mono_ms = @budget.monotonic_ms()
  assert_true(
    state.trigger_will(will_id, now_mono_ms, @async.now(), @session.DropOnClose),
  )
  let runtime = BrokerRuntime::new(config, state)
  ignore(runtime.apply(CheckDeadlines(@async.now())))
  assert_eq(state.will_count(), 1)
  assert_eq(state.next_due_will(@budget.monotonic_ms()), Some(will_id))
  assert_true(runtime.will_retry_after_mono_ms > now_mono_ms)
  let retry = runtime.will_retry_after_mono_ms
  ignore(runtime.apply(CheckDeadlines(@async.now())))
  assert_eq(runtime.will_retry_after_mono_ms, retry)
}
