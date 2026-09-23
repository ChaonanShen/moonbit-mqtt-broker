///|
fn durable_ack_fixture() -> (
  BrokerState,
  @session.ClientId,
  @session.SessionPacketId,
) raise {
  let config = BrokerConfig::new(
    2,
    2,
    0,
    max_inflight_per_session=1,
    max_inflight_total=1,
    max_pending_qos1_per_session=1,
    max_pending_qos1_total=1,
  ).unwrap()
  let state = BrokerState::new(config)
  let client = @session.ClientId::new("subscriber").unwrap()
  ignore(
    state.apply(
      CreateSessionWith({
        client_id: client,
        mode: @session.SessionMode::Persistent,
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
            qos: @session.DeliveryQoS::QoS1,
          },
        ],
      }),
    ),
  )
  let first = state
    .apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("topic").unwrap(),
        payload: b"first",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      }),
    )
    .unwrap()
  ignore(
    state.apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("topic").unwrap(),
        payload: b"second",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      }),
    ),
  )
  let id = match first[0] {
    Deliver(delivery) => delivery.packet_id.unwrap()
    _ => fail("first publication must be inflight")
  }
  (state, client, id)
}

///|
test "durable ACK prepare holds old inflight and pending until commit" {
  let (state, client, id) = durable_ack_fixture()
  let before = state.export_session_snapshot(client).unwrap()
  let occupied = state.resource_ledger().occupied()
  let prepared = state
    .prepare_durable_ack(client, id, OutboundPuback, 5L)
    .unwrap()
  assert_eq(state.export_session_snapshot(client), Some(before))
  assert_eq(state.inflight_count(), 1)
  assert_eq(state.pending_qos1_count(), 1)
  assert_eq(state.resource_ledger().committed(), occupied)
  assert_eq(prepared.delta().session_puts.length(), 1)
  prepared.cancel()
  assert_eq(state.resource_ledger().occupied(), occupied)
  let prepared = state
    .prepare_durable_ack(client, id, OutboundPuback, 5L)
    .unwrap()
  state.begin_action_scope()
  let actions = prepared.commit().unwrap()
  state.end_action_scope()
  assert_eq(state.inflight_count(), 1)
  assert_eq(state.pending_qos1_count(), 0)
  assert_true(actions.any(action => action is Deliver(_)))
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "durable ACK detects owner change before installing committed candidate" {
  let (state, client, id) = durable_ack_fixture()
  let prepared = state
    .prepare_durable_ack(client, id, OutboundPuback, 5L)
    .unwrap()
  ignore(state.apply(Puback({ client_id: client, packet_id: id })))
  assert_true(prepared.commit() is Err(InvariantViolation(_)))
  prepared.cancel()
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "ACL-dropped QoS 2 publish persists only the inbound dedup stage" {
  let (state, client, _) = durable_ack_fixture()
  let inbound_id = @session.SessionPacketId::new(9).unwrap()
  let prepared = state
    .prepare_durable_ack(client, inbound_id, InboundPublishDropped, 5L)
    .unwrap()
  assert_eq(state.inbound_qos2_count(), 0)
  assert_eq(prepared.delta().session_puts[0].session.inbound_qos2, [9])
  state.begin_action_scope()
  let actions = prepared.commit().unwrap()
  state.end_action_scope()
  assert_true(actions[0] is SendPubrec(_))
  assert_eq(state.inbound_qos2_count(), 1)
  let duplicate = state
    .prepare_durable_ack(client, inbound_id, InboundPublishDropped, 5L)
    .unwrap()
  assert_eq(duplicate.delta(), DurableDelta::empty())
  duplicate.cancel()
  assert_eq(state.check_invariants(), Ok(()))
}
