///|
async test "C-T28 MQTT5 expiry cleanup stays within one turn byte budget" {
  let base = ServerConfig::default()
  let config : ServerConfig = {
    ..base,
    protocol_config: @config.ProtocolConfig::new(
      mqtt5_enabled=true,
      max_expiry_work_per_turn=128,
    ).unwrap(),
  }
  let state = @router.BrokerState::new(config.broker_config())
  state.enable_v5_storage()
  let now_mono_ms = @budget.monotonic_ms()
  let metadata : @session.MessageMetadata = {
    ..@session.MessageMetadata::empty(),
    expiry: Some(@session.Deadline::new(now_mono_ms, 1000L, 100L).unwrap()),
  }
  for name in ["expiry/work/a", "expiry/work/b"] {
    ignore(
      state
      .apply(
        @router.PublishV5({
          publish: {
            origin: @router.Internal,
            topic: @topic.TopicName::new(name).unwrap(),
            payload: Bytes::make(180000, b'x'),
            qos: @session.QoS1,
            retain: true,
          },
          metadata,
        }),
      )
      .unwrap(),
    )
  }
  assert_eq(state.retained_count(), 2)
  let runtime = BrokerRuntime::new(config, state)
  @async.sleep(120)
  ignore(runtime.apply(CheckDeadlines(@async.now())))
  assert_eq(state.retained_count(), 1)
  ignore(runtime.apply(CheckDeadlines(@async.now())))
  assert_eq(state.retained_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}
