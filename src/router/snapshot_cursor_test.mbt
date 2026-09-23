///|
test "checkpoint cursor copies persistent state in bounded slices" {
  let config = BrokerConfig::new(
    8,
    32,
    4,
    max_inflight_per_session=1,
    max_inflight_total=2,
    max_pending_qos1_per_session=2,
    max_pending_qos1_total=4,
  ).unwrap()
  let state = BrokerState::new(config)
  let client = @session.ClientId::new("checkpoint-client").unwrap()
  ignore(
    state.apply(
      CreateSessionWith({
        client_id: client,
        mode: @session.Persistent,
        attached: true,
      }),
    ),
  )
  ignore(
    state.apply(
      Subscribe({
        client_id: client,
        entries: [
          {
            filter: @topic.TopicFilter::new("topic/#").unwrap(),
            qos: @session.QoS1,
          },
          {
            filter: @topic.TopicFilter::new("other/#").unwrap(),
            qos: @session.QoS0,
          },
        ],
      }),
    ),
  )
  for index in 0..<2 {
    ignore(
      state.apply(
        Publish({
          origin: Internal,
          topic: @topic.TopicName::new("topic/value").unwrap(),
          payload: @utf8.encode(index.to_string()),
          qos: @session.QoS1,
          retain: index == 0,
        }),
      ),
    )
  }
  ignore(
    state.apply(
      ReceiveQoS2({
        client_id: client,
        packet_id: @session.SessionPacketId::new(7).unwrap(),
        publish: None,
      }),
    ),
  )
  let baseline = state.export_snapshot()
  let cursor = state.start_snapshot_export(Map([(client, 5L)]))
  let mut turns = 0
  for ;; {
    turns += 1
    if cursor.step(1, 1024L).unwrap() {
      break
    }
    assert_true(turns < 100)
  }
  assert_true(turns > 5)
  let (snapshot, generations) = cursor.finish().unwrap()
  assert_eq(generations, [5L])
  assert_eq(
    BrokerState::from_snapshot(config, snapshot).unwrap().export_snapshot(),
    baseline,
  )
}
