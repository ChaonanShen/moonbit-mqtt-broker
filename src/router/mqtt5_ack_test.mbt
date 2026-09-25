///|
test "C-T14 MQTT5 negative PUBREC leaves pending for scheduler" {
  let config = BrokerConfig::new(8, 16, 8, max_inflight_per_session=1).unwrap()
  let state = BrokerState::new(config)
  let publisher = @session.ClientId::new("ack-pub").unwrap()
  let subscriber = @session.ClientId::new("ack-sub").unwrap()
  ignore(state.apply(CreateSession(publisher)))
  ignore(state.apply(CreateSession(subscriber)))
  ignore(
    state.apply(
      Subscribe({
        client_id: subscriber,
        entries: [
          {
            filter: @topic.TopicFilter::new("ack/#").unwrap(),
            qos: @session.QoS2,
          },
        ],
      }),
    ),
  )
  let input : PublishInput = {
    origin: Client(publisher),
    topic: @topic.TopicName::new("ack/a").unwrap(),
    payload: b"x",
    qos: @session.QoS2,
    retain: false,
  }
  let first = state.apply(Publish(input)).unwrap()
  ignore(state.apply(Publish(input)).unwrap())
  let id = match first[0] {
    Deliver(value) => value.packet_id.unwrap()
    _ => abort("expected first delivery")
  }
  let actions = state
    .apply(
      OutboundAckV5({
        client_id: subscriber,
        packet_id: id,
        kind: @session.V5Pubrec,
        negative: true,
      }),
    )
    .unwrap()
  assert_eq(actions, [
    DeliveryAcknowledged({ client_id: subscriber, packet_id: id }),
  ])
  assert_eq(state.pending_qos1_count(), 1)
  assert_eq(state.inflight_count(), 0)
  assert_true(!state.resume_pending().is_empty())
  let unknown = state
    .apply(
      OutboundAckV5({
        client_id: subscriber,
        packet_id: @session.SessionPacketId::new(65000).unwrap(),
        kind: @session.V5Pubrec,
        negative: false,
      }),
    )
    .unwrap()
  assert_true(unknown[0] is SendPubrelNotFound(_))
}
