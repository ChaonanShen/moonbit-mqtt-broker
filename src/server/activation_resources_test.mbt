///|
fn activation_runtime(overrides : Array[(String, Int64)]) -> BrokerRuntime {
  let mut resources = @budget.Limits::default()
  for item in overrides {
    let (key, value) = item
    resources = resources.with_value(key, value).unwrap()
  }
  let broker = @router.BrokerConfig::new(4, 8, 4, resources~).unwrap()
  let config = ServerConfig::new(4, 1024, 1024, 4, 8, 1000, 100, broker).unwrap()
  BrokerRuntime::new(config, @router.BrokerState::new(broker))
}

///|
fn activation_connect(
  runtime : BrokerRuntime,
  id : Int64,
  will : @protocol.WillMessage?,
) -> Array[RuntimeAction] {
  let connection_id = ConnectionId::new(id)
  ignore(runtime.apply(TransportOpened({ connection_id, accepted_at_ms: 0L })))
  runtime.apply(
    PacketReceived({
      connection_id,
      received_at_ms: 1L,
      packet: Connect({
        client_id: "same",
        clean_session: false,
        keep_alive: 0,
        username: None,
        password: None,
        will,
      }),
    }),
  )
}

///|
test "oversized candidate Will cannot kick old connection or mutate its QoS2 state" {
  let runtime = activation_runtime([("max_will_bytes_per_connection", 100L)])
  ignore(activation_connect(runtime, 1L, None))
  let id = @session.ClientId::new("same").unwrap()
  let before = runtime.broker_state().export_snapshot()
  let baseline = runtime.broker_state().managed_bytes()
  let result = activation_connect(
    runtime,
    2L,
    Some({
      topic: "will",
      payload: b"too-large",
      qos: @protocol.QoS2,
      retain: false,
    }),
  )
  assert_true(
    result.any(action => {
      action
      is SendPacketThenClose(
        { packet: Connack({ return_code: ServerUnavailable, .. }), .. }
      )
    }),
  )
  assert_eq(runtime.active_connection(id), Some(ConnectionId::new(1L)))
  assert_eq(runtime.broker_state().export_snapshot(), before)
  assert_eq(runtime.broker_state().managed_bytes(), baseline)
}

///|
test "activation scratch failure preserves old connection until resources return" {
  let runtime = activation_runtime([])
  ignore(activation_connect(runtime, 1L, None))
  let ledger = runtime.broker_state().resource_ledger()
  let pool = ledger.pool(Routing, 16777216L).unwrap()
  let blocker = pool.reserve(pool.limit() - pool.occupied()).unwrap()
  let before = runtime.broker_state().export_snapshot()
  let result = activation_connect(runtime, 2L, None)
  assert_true(
    result.any(action => {
      action
      is SendPacketThenClose(
        { packet: Connack({ return_code: ServerUnavailable, .. }), .. }
      )
    }),
  )
  assert_eq(
    runtime.active_connection(@session.ClientId::new("same").unwrap()),
    Some(ConnectionId::new(1L)),
  )
  assert_eq(runtime.broker_state().export_snapshot(), before)
  blocker.release().unwrap()
  let connected = activation_connect(runtime, 3L, None)
  assert_true(
    connected.any(action => {
      action
      is SendPacket({ packet: Connack({ return_code: Accepted, .. }), .. })
    }),
  )
}

///|
test "stored Will bytes release on orderly close and retained byte failure degrades once" {
  let runtime = activation_runtime([("max_retained_bytes_total", 0L)])
  let before = runtime.broker_state().managed_bytes()
  ignore(
    activation_connect(
      runtime,
      1L,
      Some({
        topic: "will",
        payload: b"body",
        qos: @protocol.QoS2,
        retain: true,
      }),
    ),
  )
  let active = runtime.broker_state().managed_bytes()
  assert_true(active > before + 104L)
  ignore(
    runtime.apply(
      PacketReceived({
        connection_id: ConnectionId::new(1L),
        packet: Disconnect,
        received_at_ms: 2L,
      }),
    ),
  )
  assert_eq(runtime.broker_state().managed_bytes(), active - 104L)
  ignore(
    activation_connect(
      runtime,
      2L,
      Some({
        topic: "will",
        payload: b"body",
        qos: @protocol.QoS2,
        retain: true,
      }),
    ),
  )
  ignore(
    runtime.apply(
      TransportClosed({
        connection_id: ConnectionId::new(2L),
        reason: PeerEof,
        observed_at_ms: 3L,
      }),
    ),
  )
  assert_eq(runtime.broker_state().retained_bytes(), 0L)
  assert_eq(runtime.broker_state().managed_bytes(), active - 104L)
}
