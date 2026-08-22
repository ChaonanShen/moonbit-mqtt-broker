///|
fn make_driver() -> RouterDriver {
  let config = ServerConfig::default()
  RouterDriver::new(
    BrokerRuntime::new(config, @router.BrokerState::new(config.broker_config())),
  )
}

///|
fn driver_connect_packet(
  client_id : String,
  clean_session? : Bool = true,
) -> @protocol.Packet {
  Connect({
    client_id,
    username: None,
    password: None,
    keep_alive: 10,
    clean_session,
    will: None,
  })
}

///|
fn register_sink(
  driver : RouterDriver,
  id : ConnectionId,
  sink : TransportSink,
) -> Unit {
  driver.handle(
    RegisterTransport({ connection_id: id, sink, accepted_at_ms: 0L }),
  )
}

///|
fn driver_receive(
  driver : RouterDriver,
  id : ConnectionId,
  packet : @protocol.Packet,
) -> Unit {
  driver.handle(
    Runtime(PacketReceived({ connection_id: id, packet, received_at_ms: 1L })),
  )
}

///|
test "driver encodes runtime packets into bounded outbound queue" {
  let driver = make_driver()
  let id = ConnectionId::new(1L)
  let sink = TransportSink::new(2)
  register_sink(driver, id, sink)
  driver_receive(driver, id, driver_connect_packet("driver"))
  assert_eq(sink.outbound().try_get(), Some(WriteFrame(b"\x20\x02\x00\x00")))
  assert_eq(sink.close_signal().try_get(), None)
  sink.close()
}

///|
test "driver preserves send then close as one outbound command" {
  let driver = make_driver()
  let id = ConnectionId::new(1L)
  let sink = TransportSink::new(1)
  register_sink(driver, id, sink)
  driver_receive(
    driver,
    id,
    driver_connect_packet("persistent", clean_session=false),
  )
  match sink.outbound().try_get() {
    Some(WriteFrameThenClose(frame, reason)) => {
      assert_eq(frame, b"\x20\x02\x00\x03")
      assert_eq(reason, ConnectRejected)
    }
    _ => fail("expected atomic connack and close command")
  }
  sink.close()
}

///|
test "full outbound queue closes slow consumer without blocking healthy sink" {
  let driver = make_driver()
  let slow_id = ConnectionId::new(1L)
  let healthy_id = ConnectionId::new(2L)
  let slow = TransportSink::new(1)
  let healthy = TransportSink::new(2)
  register_sink(driver, slow_id, slow)
  register_sink(driver, healthy_id, healthy)
  driver_receive(driver, slow_id, driver_connect_packet("slow"))
  driver_receive(driver, healthy_id, driver_connect_packet("healthy"))
  assert_true(slow.outbound().try_get() is Some(WriteFrame(_)))
  // Fill the queue again, then make PINGRESP overflow it.
  assert_true(slow.outbound().try_put(WriteFrame(b"occupied")))
  driver_receive(driver, slow_id, Pingreq)
  assert_eq(slow.close_signal().try_get(), Some(SlowConsumer))
  assert_false(driver.runtime().has_connection(slow_id))

  driver_receive(driver, healthy_id, Pingreq)
  assert_true(healthy.outbound().try_get() is Some(WriteFrame(_)))
  assert_eq(healthy.outbound().try_get(), Some(WriteFrame(b"\xd0\x00")))
  assert_true(driver.runtime().has_connection(healthy_id))
  slow.close()
  healthy.close()
}

///|
test "unregister makes later runtime actions harmless" {
  let driver = make_driver()
  let id = ConnectionId::new(1L)
  let sink = TransportSink::new(2)
  register_sink(driver, id, sink)
  driver.handle(UnregisterTransport(id))
  assert_eq(driver.transport_count(), 0)
  driver_receive(driver, id, driver_connect_packet("stale-sink"))
  assert_eq(sink.outbound().try_get(), None)
  sink.close()
}
