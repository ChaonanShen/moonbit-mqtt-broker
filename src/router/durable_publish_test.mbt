///|
fn durable_publish_fixture() -> (
  BrokerState,
  @session.ClientId,
  @session.ClientId,
  Map[@session.ClientId, Int64],
) {
  let config = BrokerConfig::new(
    4,
    16,
    4,
    max_inflight_per_session=2,
    max_inflight_total=4,
    max_pending_qos1_per_session=2,
    max_pending_qos1_total=4,
  ).unwrap()
  let state = BrokerState::new(config)
  let first = @session.ClientId::new("first").unwrap()
  let second = @session.ClientId::new("second").unwrap()
  for id in [first, second] {
    ignore(
      state.apply(
        CreateSessionWith({
          client_id: id,
          mode: @session.SessionMode::Persistent,
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
              filter: @topic.TopicFilter::new("data/#").unwrap(),
              qos: @session.DeliveryQoS::QoS1,
            },
          ],
        }),
      ),
    )
  }
  (state, first, second, Map([(first, 1L), (second, 2L)]))
}

///|
test "durable publish holds retained and both subscriber results until commit" {
  let (state, first, second, generations) = durable_publish_fixture()
  let before = state.export_snapshot()
  let occupied = state.resource_ledger().occupied()
  let input : PublishInput = {
    origin: Client(first),
    topic: @topic.TopicName::new("data/value").unwrap(),
    payload: b"value",
    qos: @session.DeliveryQoS::QoS1,
    retain: true,
  }
  let prepared = match state.prepare_durable_publish(input, generations) {
    Ok(value) => value
    Err(InvariantViolation(message)) => fail("invariant: " + message)
    Err(ByteResourceLimit(_)) => fail("byte budget rejection")
    Err(QoS1ResourceLimit(id, Bytes)) =>
      fail("qos1 byte rejection " + id.value())
    Err(QoS1ResourceLimit(id, InflightPerSession)) =>
      fail("qos1 inflight per session " + id.value())
    Err(QoS1ResourceLimit(id, InflightTotal)) =>
      fail("qos1 inflight total " + id.value())
    Err(QoS1ResourceLimit(id, PendingQoS1PerSession)) =>
      fail("qos1 pending per session " + id.value())
    Err(QoS1ResourceLimit(id, PendingQoS1Total)) =>
      fail("qos1 pending total " + id.value())
    Err(QoS1ResourceLimit(_, _)) => fail("qos1 other limit")
    Err(SessionFailure(_)) => fail("session stage rejection")
    Err(_) => fail("other prepare rejection")
  }
  assert_eq(state.export_snapshot(), before)
  assert_eq(state.inflight_count(), 0)
  assert_eq(state.retained_count(), 0)
  assert_eq(prepared.delta().session_puts.length(), 2)
  assert_eq(prepared.delta().retained_puts.length(), 1)
  prepared.cancel()
  assert_eq(state.resource_ledger().occupied(), occupied)
  let prepared = state.prepare_durable_publish(input, generations).unwrap()
  let accumulator = DurableAccumulator::new(state.config(), before, [1L, 2L]).unwrap()
  assert_eq(accumulator.apply(prepared.delta()), Ok(()))
  state.begin_action_scope()
  let actions = prepared.commit().unwrap()
  state.end_action_scope()
  assert_eq(actions.length(), 2)
  assert_eq(state.inflight_count(), 2)
  assert_eq(state.retained_count(), 1)
  assert_eq(accumulator.export_snapshot().0, state.export_snapshot())
  assert_true(state.session_inflight_count(first) == Some(1))
  assert_true(state.session_inflight_count(second) == Some(1))
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "QoS 0 durable retained result never upgrades subscriber delivery" {
  let (state, first, _, generations) = durable_publish_fixture()
  let plan = state
    .prepare_durable_publish(
      {
        origin: Client(first),
        topic: @topic.TopicName::new("data/value").unwrap(),
        payload: b"value",
        qos: @session.DeliveryQoS::QoS0,
        retain: true,
      },
      generations,
    )
    .unwrap()
  assert_eq(plan.delta().session_puts.length(), 0)
  assert_eq(plan.delta().retained_puts[0].qos, 0)
  state.begin_action_scope()
  let actions = plan.commit().unwrap()
  state.end_action_scope()
  assert_eq(actions.length(), 2)
  assert_eq(state.inflight_count(), 0)
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "inbound QoS 2 ID and durable fanout share one prepared publication" {
  let (state, first, second, generations) = durable_publish_fixture()
  let packet_id = @session.SessionPacketId::new(7).unwrap()
  let before = state.export_snapshot()
  let plan = state
    .prepare_durable_publish(
      {
        origin: Client(first),
        topic: @topic.TopicName::new("data/qos2").unwrap(),
        payload: b"once",
        qos: @session.DeliveryQoS::QoS2,
        retain: true,
      },
      generations,
      inbound_packet_id=packet_id,
    )
    .unwrap()
  assert_eq(state.inbound_qos2_count(), 0)
  assert_eq(state.export_snapshot(), before)
  assert_true(
    plan.delta().session_puts.any(item => {
      item.session.client_id == first.value() &&
      item.session.inbound_qos2 == [7]
    }),
  )
  state.begin_action_scope()
  let actions = plan.commit().unwrap()
  state.end_action_scope()
  assert_true(actions[0] is SendPubrec(_))
  assert_eq(state.inbound_qos2_count(), 1)
  assert_eq(state.session_inflight_count(first), Some(1))
  assert_eq(state.session_inflight_count(second), Some(1))
  assert_eq(state.check_invariants(), Ok(()))
  let completion = state
    .prepare_durable_ack(first, packet_id, InboundPubrel, 1L)
    .unwrap()
  assert_eq(state.inbound_qos2_count(), 1)
  state.begin_action_scope()
  let completed_actions = completion.commit().unwrap()
  state.end_action_scope()
  assert_true(completed_actions[0] is SendPubcomp(_))
  assert_eq(state.inbound_qos2_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "missing persistent generation rejects publish without leaking reservations" {
  let (state, first, _, _) = durable_publish_fixture()
  let before = state.export_snapshot()
  let occupied = state.resource_ledger().occupied()
  assert_true(
    state.prepare_durable_publish(
      {
        origin: Client(first),
        topic: @topic.TopicName::new("data/value").unwrap(),
        payload: b"value",
        qos: @session.DeliveryQoS::QoS1,
        retain: true,
      },
      Map([]),
    )
    is Err(InvariantViolation(_)),
  )
  assert_eq(state.export_snapshot(), before)
  assert_eq(state.resource_ledger().occupied(), occupied)
}
