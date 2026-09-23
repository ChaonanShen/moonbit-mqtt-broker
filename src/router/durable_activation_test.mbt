///|
test "durable activation creates persistent session only after commit" {
  let state = BrokerState::new(BrokerConfig::new(4, 16, 4).unwrap())
  let client = @session.ClientId::new("new-client").unwrap()
  let before = state.resource_ledger().occupied()
  let first = state
    .prepare_durable_activation(
      client,
      @session.Persistent,
      @security.Principal::Anonymous,
      0L,
      1L,
    )
    .unwrap()
  assert_false(first.session_present())
  assert_eq(first.delta().session_puts[0].generation, 1L)
  assert_eq(state.session_count(), 0)
  first.cancel()
  assert_eq(state.resource_ledger().occupied(), before)
  let second = state
    .prepare_durable_activation(
      client,
      @session.Persistent,
      @security.Principal::Anonymous,
      0L,
      1L,
    )
    .unwrap()
  state.begin_action_scope()
  assert_eq(second.commit(), Ok([]))
  state.end_action_scope()
  assert_eq(state.session_count(), 1)
  assert_eq(state.session_attached(client), Some(true))
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "durable activation preserves persistent generation on restore and deletes on clean reset" {
  let state = BrokerState::new(BrokerConfig::new(4, 16, 4).unwrap())
  let client = @session.ClientId::new("reconnect").unwrap()
  ignore(
    state.apply(
      CreateSessionWith({
        client_id: client,
        mode: @session.Persistent,
        attached: false,
      }),
    ),
  )
  let before = state.export_snapshot()
  let reconnect = state
    .prepare_durable_activation(
      client,
      @session.Persistent,
      @security.Principal::Anonymous,
      7L,
      7L,
    )
    .unwrap()
  assert_true(reconnect.session_present())
  assert_eq(state.export_snapshot(), before)
  assert_eq(reconnect.delta().session_puts[0].generation, 7L)
  state.begin_action_scope()
  ignore(reconnect.commit().unwrap())
  state.end_action_scope()
  assert_eq(state.session_attached(client), Some(true))
  let clean = state
    .prepare_durable_activation(
      client,
      @session.Clean,
      @security.Principal::Anonymous,
      7L,
      0L,
    )
    .unwrap()
  assert_eq(clean.delta().session_deletes[0].expected_generation, 7L)
  state.begin_action_scope()
  ignore(clean.commit().unwrap())
  state.end_action_scope()
  assert_eq(state.session_mode(client), Some(@session.Clean))
  assert_eq(state.export_snapshot().sessions.length(), 0)
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "durable reconnect promotes pending in the same committed session result" {
  let state = BrokerState::new(
    BrokerConfig::new(
      4,
      16,
      4,
      max_inflight_per_session=1,
      max_inflight_total=2,
    ).unwrap(),
  )
  let client = @session.ClientId::new("offline").unwrap()
  ignore(
    state.apply(
      CreateSessionWith({
        client_id: client,
        mode: @session.Persistent,
        attached: false,
      }),
    ),
  )
  ignore(
    state.apply(
      Subscribe({
        client_id: client,
        entries: [
          {
            filter: @topic.TopicFilter::new("queued").unwrap(),
            qos: @session.QoS1,
          },
        ],
      }),
    ),
  )
  ignore(
    state.apply(
      Publish({
        origin: Internal,
        topic: @topic.TopicName::new("queued").unwrap(),
        payload: b"waiting",
        qos: @session.QoS1,
        retain: false,
      }),
    ),
  )
  assert_eq(state.pending_qos1_count(), 1)
  let prepared = state
    .prepare_durable_activation(
      client,
      @session.Persistent,
      @security.Principal::Anonymous,
      5L,
      5L,
    )
    .unwrap()
  assert_eq(prepared.delta().session_puts[0].session.pending.length(), 0)
  assert_eq(prepared.delta().session_puts[0].session.inflight.length(), 1)
  assert_eq(state.pending_qos1_count(), 1)
  state.begin_action_scope()
  let replay = prepared.commit().unwrap()
  state.end_action_scope()
  match replay[0] {
    Deliver(value) => assert_false(value.dup)
    _ => fail("pending delivery must be promoted")
  }
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(state.inflight_count(), 1)
  assert_eq(state.check_invariants(), Ok(()))
}
