///|
test "qos2 acknowledgement queue failures preserve committed persistent phases" {
  for failure_stage in 0..<3 {
    let config = ServerConfig::default()
    let runtime = BrokerRuntime::new(
      config,
      @router.BrokerState::new(config.broker_config()),
    )
    let driver = RouterDriver::new(runtime)
    let old = ConnectionId::new(201L)
    let sink = TransportSink::new(4)
    driver.handle(
      RegisterTransport({ connection_id: old, sink, accepted_at_ms: 0L }),
    )
    let connect : @protocol.Packet = Connect({
      client_id: "qos2-write-failure",
      username: None,
      password: None,
      clean_session: false,
      keep_alive: 0,
      will: None,
    })
    driver.handle(
      Runtime(
        PacketReceived({
          connection_id: old,
          packet: connect,
          received_at_ms: 1L,
        }),
      ),
    )
    ignore(sink.outbound().try_get())
    driver.handle(
      Runtime(
        PacketReceived({
          connection_id: old,
          received_at_ms: 2L,
          packet: Subscribe({
            packet_id: @protocol.PacketId::new(55).unwrap(),
            subscriptions: [{ topic_filter: "q2", requested_qos: QoS2 }],
          }),
        }),
      ),
    )
    ignore(sink.outbound().try_get())
    let incoming = @protocol.PacketId::new(77).unwrap()
    let outgoing = @protocol.PacketId::new(1).unwrap()
    let publish : @protocol.Packet = Publish({
      topic: "q2",
      payload: b"saved",
      qos: QoS2,
      packet_id: Some(incoming),
      dup: false,
      retain: false,
    })
    if failure_stage > 0 {
      driver.handle(
        Runtime(
          PacketReceived({
            connection_id: old,
            packet: publish,
            received_at_ms: 3L,
          }),
        ),
      )
      ignore(sink.outbound().try_get())
      ignore(sink.outbound().try_get())
    }
    if failure_stage == 2 {
      driver.handle(
        Runtime(
          PacketReceived({
            connection_id: old,
            packet: Pubrec(outgoing),
            received_at_ms: 4L,
          }),
        ),
      )
      ignore(sink.outbound().try_get())
    }
    for _ in 0..<4 {
      driver.dispatch([SendPacket({ connection_id: old, packet: Pingresp })])
    }
    let packet = match failure_stage {
      0 => publish
      1 => @protocol.Packet::Pubrec(outgoing)
      _ => @protocol.Packet::Pubrel(incoming)
    }
    driver.handle(
      Runtime(
        PacketReceived({ connection_id: old, packet, received_at_ms: 5L }),
      ),
    )
    assert_eq(sink.close_signal().try_get(), Some(SlowConsumer))
    assert_false(runtime.has_connection(old))
    assert_eq(
      runtime.broker_state().inbound_qos2_count(),
      if failure_stage == 2 {
        0
      } else {
        1
      },
    )
    assert_eq(
      runtime
      .broker_state()
      .phase_count(
        if failure_stage == 0 {
          @session.OutboundPhase::AwaitPubrec
        } else {
          @session.OutboundPhase::AwaitPubcomp
        },
      ),
      1,
    )
    let next = ConnectionId::new(202L)
    let resumed = TransportSink::new(4)
    driver.handle(
      RegisterTransport({
        connection_id: next,
        sink: resumed,
        accepted_at_ms: 6L,
      }),
    )
    driver.handle(
      Runtime(
        PacketReceived({
          connection_id: next,
          packet: connect,
          received_at_ms: 7L,
        }),
      ),
    )
    match resumed.outbound().try_get() {
      Some(WriteFrame(bytes)) =>
        assert_eq(
          @protocol.decode_packet(bytes),
          Ok(Connack({ session_present: true, return_code: Accepted })),
        )
      _ => fail("CONNACK must precede replay")
    }
    match resumed.outbound().try_get() {
      Some(WriteFrame(bytes)) =>
        if failure_stage == 0 {
          assert_true(
            @protocol.decode_packet(bytes)
            is Ok(Publish({ qos: QoS2, dup: true, .. })),
          )
        } else {
          assert_eq(bytes, b"\x62\x02\x00\x01")
        }
      _ => fail("incomplete exchange must replay")
    }
    assert_eq(runtime.check_invariants(), Ok(()))
    sink.close()
    resumed.close()
  }
}
