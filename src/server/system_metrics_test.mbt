///|
test "system metrics are qos0 read-only and do not feed back into state" {
  let metrics = BrokerMetrics::new(1000L)
  let config = runtime_config()
  let rt = BrokerRuntime::new(
    config,
    @router.BrokerState::new(config.broker_config()),
    metrics~,
  )
  let system_client = cid(1L)
  let ordinary_wildcard = cid(2L)
  connect(rt, system_client, "system-reader")
  connect(rt, ordinary_wildcard, "ordinary-reader")
  ignore(
    receive(
      rt,
      system_client,
      Subscribe({
        packet_id: @protocol.PacketId::new(1).unwrap(),
        subscriptions: [{ topic_filter: "$SYS/broker/#", requested_qos: QoS1 }],
      }),
      2L,
    ),
  )
  ignore(
    receive(
      rt,
      ordinary_wildcard,
      Subscribe({
        packet_id: @protocol.PacketId::new(2).unwrap(),
        subscriptions: [{ topic_filter: "#", requested_qos: QoS0 }],
      }),
      2L,
    ),
  )
  let revision = rt.broker_state().snapshot_revision()
  let retained = rt.broker_state().retained_count()
  let actions = rt.apply(
    EmitSystemMetrics({ now_ms: 3500L, persistence_state: "healthy" }),
  )
  assert_eq(actions.length(), 15)
  for action in actions {
    match action {
      SendPacket({ connection_id, packet: Publish(packet) }) => {
        assert_eq(connection_id, system_client)
        assert_true(packet.topic.has_prefix("$SYS/broker/"))
        assert_eq(packet.qos, QoS0)
        assert_false(packet.retain)
      }
      _ => fail("expected internal QoS 0 metric")
    }
  }
  assert_eq(rt.broker_state().snapshot_revision(), revision)
  assert_eq(rt.broker_state().retained_count(), retained)
  assert_eq(metrics.messages_sent(), 0L)
  assert_eq(metrics.messages_received(), 0L)
  assert_eq(
    rt
    .apply(EmitSystemMetrics({ now_ms: 4500L, persistence_state: "degraded" }))
    .length(),
    15,
  )
  assert_eq(metrics.messages_sent(), 0L)
}

///|
test "message authentication acl drop and tls counters are exact" {
  let metrics = BrokerMetrics::new(0L)
  let config = runtime_config()
  let rt = BrokerRuntime::new(
    config,
    @router.BrokerState::new(config.broker_config()),
    metrics~,
  )
  let publisher = cid(1L)
  connect(rt, publisher, "publisher")
  assert_eq(
    receive(
      rt,
      publisher,
      Publish({
        topic: "ordinary/topic",
        payload: b"counted",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: false,
      }),
      2L,
    ),
    [],
  )
  assert_eq(
    receive(
      rt,
      publisher,
      Publish({
        topic: "$SYS/broker/forged",
        payload: b"secret-payload",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: true,
      }),
      3L,
    ),
    [],
  )
  metrics.record_tls_handshake_failure()
  assert_eq(metrics.messages_received(), 2L)
  assert_eq(metrics.messages_sent(), 0L)
  assert_eq(metrics.messages_dropped(), 1L)
  assert_eq(metrics.acl_denials(), 1L)
  assert_eq(metrics.tls_handshake_failures(), 1L)
  assert_eq(rt.broker_state().retained_count(), 0)

  let denied_metrics = BrokerMetrics::new(0L)
  let denied = BrokerRuntime::new(
    config,
    @router.BrokerState::new(config.broker_config()),
    security=@security.SecurityPolicy::new(allow_anonymous=false),
    metrics=denied_metrics,
  )
  open(denied, cid(9L), 0L)
  assert_eq(receive(denied, cid(9L), connect_packet("denied"), 1L).length(), 1)
  assert_eq(denied_metrics.authentication_failures(), 1L)
}
