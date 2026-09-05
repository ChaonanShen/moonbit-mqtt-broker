///|
test "qos2 fanout and retained admission failure leaves all state unchanged" {
  let config = BrokerConfig::new(
    4,
    16,
    2,
    max_inflight_per_session=0,
    max_pending_per_session=1,
    max_pending_total=2,
  ).unwrap()
  let state = BrokerState::new(config)
  let publisher = @session.ClientId::new("publisher").unwrap()
  ignore(
    state
    .apply(
      CreateSessionWith({
        client_id: publisher,
        mode: Persistent,
        attached: true,
      }),
    )
    .unwrap(),
  )
  for name in ["a", "z"] {
    let client_id = @session.ClientId::new(name).unwrap()
    ignore(
      state
      .apply(
        CreateSessionWith({ client_id, mode: Persistent, attached: false }),
      )
      .unwrap(),
    )
    ignore(
      state
      .apply(
        Subscribe({
          client_id,
          entries: [
            { filter: @topic.TopicFilter::new("q2/#").unwrap(), qos: QoS2 },
          ],
        }),
      )
      .unwrap(),
    )
  }
  let saturated = @session.ClientId::new("z").unwrap()
  ignore(
    state
    .apply(
      Subscribe({
        client_id: saturated,
        entries: [
          { filter: @topic.TopicFilter::new("only/z").unwrap(), qos: QoS2 },
        ],
      }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("only/z").unwrap(),
        payload: b"full",
        qos: QoS2,
        retain: false,
      }),
    )
    .unwrap(),
  )
  ignore(
    state
    .apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("q2/old").unwrap(),
        payload: b"old",
        qos: QoS0,
        retain: true,
      }),
    )
    .unwrap(),
  )
  let before = state.export_snapshot()
  let revision = state.snapshot_revision()
  assert_true(
    state.apply(
      ReceiveQoS2({
        client_id: publisher,
        packet_id: @session.SessionPacketId::new(1).unwrap(),
        publish: Some({
          origin: Client(publisher),
          topic: @topic.TopicName::new("q2/old").unwrap(),
          payload: b"replacement",
          qos: QoS2,
          retain: true,
        }),
      }),
    )
    is Err(QoS1ResourceLimit(_, _)),
  )
  assert_eq(state.export_snapshot(), before)
  assert_eq(state.snapshot_revision(), revision)
  assert_eq(state.inbound_qos2_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "qos2 inbound budgets survive restore and reclaim on pubrel remove and expiry" {
  let config = BrokerConfig::new(
    1,
    3,
    0,
    max_inbound_qos2_per_session=1,
    max_inbound_qos2_total=2,
    persistent_session_expiry_ms=1L,
  ).unwrap()
  let state = BrokerState::new(config)
  let clients = ["a", "b", "c"].map(name => {
    @session.ClientId::new(name).unwrap()
  })
  let id = @session.SessionPacketId::new(1).unwrap()
  for client_id in clients {
    ignore(
      state
      .apply(CreateSessionWith({ client_id, mode: Persistent, attached: true }))
      .unwrap(),
    )
  }
  for client_id in [clients[0], clients[1]] {
    ignore(
      state
      .apply(ReceiveQoS2({ client_id, packet_id: id, publish: None }))
      .unwrap(),
    )
  }
  let before = state.export_snapshot()
  assert_true(
    state.apply(
      ReceiveQoS2({ client_id: clients[2], packet_id: id, publish: None }),
    )
    is Err(InboundQoS2ResourceLimit(InboundQoS2Total)),
  )
  assert_eq(state.export_snapshot(), before)
  assert_eq(
    state.apply(
      ReceiveQoS2({
        client_id: clients[0],
        packet_id: @session.SessionPacketId::new(2).unwrap(),
        publish: None,
      }),
    ),
    Err(InboundQoS2ResourceLimit(InboundQoS2PerSession)),
  )
  assert_true(
    BrokerState::from_snapshot(
      BrokerConfig::new(1, 3, 0, max_inbound_qos2_total=1).unwrap(),
      before,
    )
    is Err(SnapshotError::LimitExceeded(_)),
  )
  ignore(state.apply(Pubrel({ client_id: clients[0], packet_id: id })).unwrap())
  ignore(
    state
    .apply(ReceiveQoS2({ client_id: clients[2], packet_id: id, publish: None }))
    .unwrap(),
  )
  ignore(state.apply(RemoveSession(clients[1])).unwrap())
  ignore(
    state
    .apply(DetachSessionAt({ client_id: clients[2], detached_at_ms: 10L }))
    .unwrap(),
  )
  ignore(state.apply(ExpireSessions(12L)).unwrap())
  assert_eq(state.inbound_qos2_count(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "qos pending aliases share limits and reject ambiguous configuration" {
  assert_true(
    BrokerConfig::new(
      1,
      1,
      1,
      max_pending_per_session=1,
      max_pending_qos1_per_session=1,
    )
    is Err(InvalidConfiguration(_)),
  )
  assert_true(
    BrokerConfig::new(1, 1, 1, max_pending_total=1, max_pending_qos1_total=2)
    is Err(InvalidConfiguration(_)),
  )
  assert_true(
    BrokerConfig::new(1, 1, 1, max_inbound_qos2_per_session=65536) is Err(_),
  )
  let config = BrokerConfig::new(1, 1, 1, max_pending_total=5).unwrap()
  assert_eq(config.max_pending_total(), config.max_pending_qos1_total())
}
