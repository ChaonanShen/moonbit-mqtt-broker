///|
test "C-T22 cancelled alias definition cannot be reused" {
  let sink = TransportSink::new(4)
  let first = sink.propose_outbound_alias("sensors/a", 4, 4096)
  assert_eq(first, AliasDefine(1, "sensors/a"))
  assert_eq(sink.propose_outbound_alias("sensors/a", 4, 4096), AliasNone)
  sink.outbound_alias_cancel(first)
  let second = sink.propose_outbound_alias("sensors/a", 4, 4096)
  assert_eq(second, AliasDefine(1, "sensors/a"))
  sink.outbound_alias_written(second)
  assert_eq(sink.propose_outbound_alias("sensors/a", 4, 4096), AliasReuse(1))
  sink.close()
}

///|
test "C-T22 alias budget prevents uncharged definitions" {
  let sink = TransportSink::new(4)
  assert_eq(sink.propose_outbound_alias("long/topic", 4, 5), AliasNone)
  let first = sink.propose_outbound_alias("long/topic", 4, 74)
  assert_eq(first, AliasDefine(1, "long/topic"))
  assert_eq(sink.propose_outbound_alias("other/topic", 4, 74), AliasNone)
  sink.close()
}

///|
test "C-T27 alias byte quota is shared across inbound and outbound tables" {
  let sink = TransportSink::new(4)
  let connection_id = ConnectionId::new(61L)
  let inbound : Map[ConnectionId, Map[Int, String]] = Map([])
  inbound.set(connection_id, Map([(1, "in/a")]))
  let outbound : Map[ConnectionId, Int] = Map([])
  sink.bind_alias_budget(connection_id, inbound, outbound)
  assert_eq(
    sink.propose_outbound_alias("out/a", 2, 137),
    AliasDefine(1, "out/a"),
  )
  sink.outbound_alias_written(AliasDefine(1, "out/a"))
  assert_eq(outbound.get(connection_id), Some(69))
  assert_eq(sink.propose_outbound_alias("out/b", 2, 200), AliasNone)
  sink.close()
  assert_eq(outbound.get(connection_id), None)

  let base = ServerConfig::default()
  let config : ServerConfig = {
    ..base,
    protocol_config: @config.ProtocolConfig::new(
      mqtt5_enabled=true,
      max_alias_bytes_per_connection=100,
    ).unwrap(),
  }
  let runtime = BrokerRuntime::new(
    config,
    @router.BrokerState::new(config.broker_config()),
  )
  runtime.inbound_aliases.set(connection_id, Map([]))
  runtime.outbound_alias_bytes.set(connection_id, 69)
  let client_id = @session.ClientId::new("alias-budget").unwrap()
  let packet : @protocol.PublishV5 = {
    topic: "in/a",
    payload: b"x",
    qos: @protocol.QoS0,
    packet_id: None,
    dup: false,
    retain: false,
    properties: [{ id: 0x23, value: @protocol.TwoByteValue(1) }],
  }
  assert_eq(
    runtime.normalize_mqtt5_publish(
      connection_id,
      client_id,
      packet,
      @budget.monotonic_ms(),
      1000L,
    ),
    Err({ reason: 0x97 }),
  )
  assert_eq(runtime.inbound_aliases.get(connection_id).unwrap().length(), 0)
}

///|
test "C-T22 out-of-order alias cancellation reuses smallest free identity once" {
  let sink = TransportSink::new(8)
  let first = sink.propose_outbound_alias("alias/a", 4, 4096)
  let second = sink.propose_outbound_alias("alias/b", 4, 4096)
  assert_eq(first, AliasDefine(1, "alias/a"))
  assert_eq(second, AliasDefine(2, "alias/b"))
  sink.outbound_alias_cancel(first)
  sink.outbound_alias_cancel(first)
  assert_eq(
    sink.propose_outbound_alias("alias/c", 4, 4096),
    AliasDefine(1, "alias/c"),
  )
  sink.outbound_alias_written(second)
  assert_eq(sink.propose_outbound_alias("alias/b", 4, 4096), AliasReuse(2))
  assert_eq(sink.free_outbound_aliases.length(), 0)
  sink.close()
}
