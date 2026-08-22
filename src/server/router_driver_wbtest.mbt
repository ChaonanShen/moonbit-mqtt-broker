///|
test "encode failure isolates healthy clients" {
  let config = ServerConfig::default()
  let runtime = BrokerRuntime::new(
    config,
    @router.BrokerState::new(config.broker_config()),
  )
  let driver = RouterDriver::new(runtime)
  let failing_id = ConnectionId::new(91L)
  let healthy_id = ConnectionId::new(92L)
  let failing = TransportSink::new(2)
  let healthy = TransportSink::new(2)
  driver.handle(
    RegisterTransport({
      connection_id: failing_id,
      sink: failing,
      accepted_at_ms: 0L,
    }),
  )
  driver.handle(
    RegisterTransport({
      connection_id: healthy_id,
      sink: healthy,
      accepted_at_ms: 0L,
    }),
  )
  for pair in [(failing_id, "encode-failing"), (healthy_id, "encode-healthy")] {
    let (connection_id, client_id) = pair
    driver.handle(
      Runtime(
        PacketReceived({
          connection_id,
          packet: Connect({
            client_id,
            username: None,
            password: None,
            keep_alive: 0,
            clean_session: true,
            will: None,
          }),
          received_at_ms: 1L,
        }),
      ),
    )
  }
  assert_true(failing.outbound().try_get() is Some(WriteFrame(_)))
  assert_true(healthy.outbound().try_get() is Some(WriteFrame(_)))

  driver.dispatch([
    SendPacket({
      connection_id: failing_id,
      packet: Publish({
        topic: "unsupported/qos2",
        payload: b"fail",
        qos: QoS2,
        packet_id: Some(@protocol.PacketId::new(1).unwrap()),
        dup: false,
        retain: false,
      }),
    }),
    SendPacket({ connection_id: healthy_id, packet: Pingresp }),
  ])
  assert_eq(failing.close_signal().try_get(), Some(EncodeFailure))
  assert_eq(healthy.outbound().try_get(), Some(WriteFrame(b"\xd0\x00")))
  assert_false(driver.runtime().has_connection(failing_id))
  assert_true(driver.runtime().has_connection(healthy_id))
  failing.close()
  healthy.close()
}
