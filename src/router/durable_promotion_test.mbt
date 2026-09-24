///|
test "durable promotion waits for freed global slot then records new Packet ID" {
  let state = BrokerState::new(
    BrokerConfig::new(
      2,
      4,
      0,
      max_inflight_per_session=1,
      max_inflight_total=1,
      max_pending_qos1_per_session=2,
      max_pending_qos1_total=2,
    ).unwrap(),
  )
  let first = @session.ClientId::new("first").unwrap()
  let second = @session.ClientId::new("second").unwrap()
  for id in [first, second] {
    ignore(
      state.apply(
        CreateSessionWith({
          client_id: id,
          mode: @session.Persistent,
          attached: true,
        }),
      ),
    )
    ignore(
      state.apply(
        Subscribe({
          client_id: id,
          entries: [
            {
              filter: @topic.TopicFilter::new("topic").unwrap(),
              qos: @session.QoS1,
            },
          ],
        }),
      ),
    )
  }
  let routed = state
    .apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("topic").unwrap(),
        payload: b"value",
        qos: @session.QoS1,
        retain: false,
      }),
    )
    .unwrap()
  let (inflight_id, pending_id, packet_id) = match routed[0] {
    Deliver(value) =>
      (
        value.recipient,
        if value.recipient == first {
          second
        } else {
          first
        },
        value.packet_id.unwrap(),
      )
    _ => fail("first recipient must get inflight message")
  }
  assert_eq(state.inflight_count(), 1)
  assert_eq(state.pending_qos1_count(), 1)
  assert_true(state.next_durable_promotion() is None)
  let ack = state
    .prepare_durable_ack(inflight_id, packet_id, OutboundPuback, 1L)
    .unwrap()
  state.begin_action_scope()
  ignore(ack.commit().unwrap())
  state.end_action_scope()
  assert_eq(state.inflight_count(), 0)
  assert_eq(state.next_durable_promotion(), Some(pending_id))
  let plan = state
    .prepare_durable_ack(
      pending_id,
      @session.SessionPacketId::new(1).unwrap(),
      PendingPromotion,
      2L,
    )
    .unwrap()
  assert_eq(state.pending_qos1_count(), 1)
  assert_eq(plan.delta().session_puts.length(), 1)
  state.begin_action_scope()
  let actions = plan.commit().unwrap()
  state.end_action_scope()
  assert_true(actions[0] is Deliver(_))
  assert_eq(state.inflight_count(), 1)
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "tightened ACL blocks pending promotion before Packet ID allocation" {
  let state = BrokerState::new(
    BrokerConfig::new(
      2,
      4,
      0,
      max_inflight_per_session=1,
      max_inflight_total=1,
      max_pending_qos1_per_session=2,
      max_pending_qos1_total=2,
    ).unwrap(),
  )
  let client = @session.ClientId::new("client").unwrap()
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
            filter: @topic.TopicFilter::new("topic").unwrap(),
            qos: @session.QoS1,
          },
        ],
      }),
    ),
  )
  let input : PublishInput = {
    origin: Internal,
    topic: @topic.TopicName::new("topic").unwrap(),
    payload: b"value",
    qos: @session.QoS1,
    retain: false,
  }
  let first = state.apply(Publish(input)).unwrap()
  let packet_id = match first[0] {
    Deliver(value) => value.packet_id.unwrap()
    _ => fail("first publish must be inflight")
  }
  ignore(state.apply(Publish(input)))
  assert_eq(state.inflight_count(), 1)
  assert_eq(state.pending_qos1_count(), 1)
  let acl = @security.AclPolicy::parse("").unwrap()
  assert_true(state.set_security_policy(@security.SecurityPolicy::new(acl~)))
  let ack = state.apply(Puback({ client_id: client, packet_id })).unwrap()
  assert_false(ack.any(action => action is Deliver(_)))
  assert_eq(state.inflight_count(), 0)
  assert_eq(state.pending_qos1_count(), 1)
  assert_eq(state.next_durable_promotion(), None)
  assert_eq(state.resume_pending(), [])
  assert_eq(state.check_invariants(), Ok(()))
}
