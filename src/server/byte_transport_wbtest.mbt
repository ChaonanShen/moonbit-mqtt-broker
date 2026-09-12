///|
fn bus_fixture(
  capacity? : Int = 2,
) -> (EventBus, @router.BrokerState, RouterDriver) {
  let router = @router.BrokerConfig::new(4, 8, 4).unwrap()
  let config = ServerConfig::new(16, 1024, 1024, 4, capacity, 1000, 100, router).unwrap()
  let state = @router.BrokerState::new(router)
  let data = @async.Queue(kind=Blocking(capacity))
  let bus = EventBus::new(config, state.resource_ledger(), data).unwrap()
  let driver = RouterDriver::new(BrokerRuntime::new(config, state))
  (bus, state, driver)
}

///|
test "outbound dequeue retains writing budget and close only releases queued frames" {
  let (bus, state, _) = bus_fixture()
  let sink = TransportSink::new(2)
  ignore(bus.register(ConnectionId::new(1L), sink).unwrap())
  let baseline = state.managed_bytes()
  let first = b"abc"
  let second = b"defgh"
  assert_true(
    sink.enqueue_frame(first, sink.reserve_frame(10L, false).unwrap(), None),
  )
  assert_true(
    sink.enqueue_frame(second, sink.reserve_frame(10L, false).unwrap(), None),
  )
  assert_eq(state.managed_bytes(), baseline + 8L)
  assert_eq(sink.outbound().try_get(), Some(WriteFrame(first)))
  let writing = sink.take_frame_ticket(first).unwrap()
  sink.close()
  assert_eq(state.managed_bytes(), baseline + 3L)
  writing.release().unwrap()
  assert_eq(state.managed_bytes(), baseline)
  sink.close()
  bus.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
test "outbound queue rejection rolls back reservation without losing queued ownership" {
  let (bus, state, _) = bus_fixture()
  let sink = TransportSink::new(1)
  ignore(bus.register(ConnectionId::new(1L), sink).unwrap())
  let baseline = state.managed_bytes()
  assert_true(
    sink.enqueue_frame(b"one", sink.reserve_frame(3L, false).unwrap(), None),
  )
  assert_false(
    sink.enqueue_frame(b"two", sink.reserve_frame(3L, false).unwrap(), None),
  )
  assert_eq(state.managed_bytes(), baseline + 3L)
  bus.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
async test "control terminal waits for admitted packets but tick bypasses full data queue" {
  let (bus, state, _) = bus_fixture(capacity=1)
  let id = ConnectionId::new(1L)
  let budget = bus.register(id, TransportSink::new(1)).unwrap()
  let ticket = budget.control_events.reserve(128L).unwrap()
  ticket.commit().unwrap()
  assert_true(
    bus.post_packet(
      { connection_id: id, packet: @protocol.Pingreq, received_at_ms: 0L },
      ticket,
    ),
  )
  bus.terminal({ connection_id: id, reason: PeerEof, observed_at_ms: 1L })
  bus.post_tick(CheckDeadlines(1L))
  bus.post_tick(AuthenticationPollDue(2L))
  assert_true(bus.next() is Some(Runtime(CheckDeadlines(1L))))
  assert_true(bus.next() is Some(Runtime(AuthenticationPollDue(2L))))
  assert_true(bus.next() is Some(RegisterTransport(_)))
  let event = bus.next().unwrap()
  assert_true(event is Accounted(PacketReceived(_), _))
  ticket.release().unwrap()
  bus.completed(event)
  assert_true(bus.next() is Some(Runtime(TransportClosed(_))))
  assert_true(bus.next() is Some(UnregisterTransport(_)))
  bus.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
async test "registration cannot be bypassed when control fairness yields to queued data" {
  let (bus, state, _) = bus_fixture(capacity=16)
  for value in 1..<=12 {
    let id = ConnectionId::new(value.to_int64())
    let budget = bus.register(id, TransportSink::new(1)).unwrap()
    let ticket = budget.control_events.reserve(128L).unwrap()
    ticket.commit().unwrap()
    assert_true(
      bus.post_packet(
        { connection_id: id, packet: @protocol.Pingreq, received_at_ms: 0L },
        ticket,
      ),
    )
  }
  let registered : Map[ConnectionId, Bool] = Map([])
  let mut packets = 0
  while packets < 12 {
    let event = bus.next().unwrap()
    match event {
      RegisterTransport(reg) => registered.set(reg.connection_id, true)
      Accounted(PacketReceived(packet), ticket) => {
        assert_true(registered.contains(packet.connection_id))
        ticket.release().unwrap()
        bus.completed(event)
        packets += 1
      }
      _ => fail("unexpected control")
    }
  }
  bus.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
async test "cancelled capacity waiter releases its owned packet without a payload writer tombstone" {
  @async.with_task_group() <| group => {
    let (bus, state, _) = bus_fixture(capacity=1)
    let id = ConnectionId::new(1L)
    let budget = bus.register(id, TransportSink::new(1)).unwrap()
    let baseline = state.managed_bytes()
    let first = budget.events.reserve(129L).unwrap()
    first.commit().unwrap()
    assert_true(
      bus.post_packet(
        { connection_id: id, packet: @protocol.Pingreq, received_at_ms: 0L },
        first,
      ),
    )
    let started = @async.Queue(kind=Blocking(1))
    let finished = @async.Queue(kind=Blocking(1))
    let waiter = group.spawn(allow_failure=true) <| () => {
      let second = budget.events.reserve(129L).unwrap()
      defer {
        second.release().unwrap()
        ignore(finished.try_put(())) catch {
          _ => ()
        }
      }
      ignore(started.try_put(()))
      assert_false(
        bus.post_packet(
          { connection_id: id, packet: @protocol.Pingreq, received_at_ms: 0L },
          second,
        ),
      )
    }
    started.get()
    assert_eq(state.managed_bytes(), baseline + 258L)
    waiter.cancel()
    finished.get()
    assert_eq(state.managed_bytes(), baseline + 129L)
    bus.close()
    assert_eq(state.managed_bytes(), 0L)
  }
}

///|
test "control encoding and input leases work at exact ordinary saturation" {
  let (bus, state, driver) = bus_fixture()
  let sink = TransportSink::new(2)
  ignore(bus.register(ConnectionId::new(1L), sink).unwrap())
  let ledger = state.resource_ledger()
  let filler = ledger
    .pool(LimiterMetadata, 268435456L)
    .unwrap()
    .reserve(ledger.ordinary_available())
    .unwrap()
  filler.commit().unwrap()
  state.begin_action_scope()
  assert_eq(state.admit_action_input(256L, control=true), Ok(()))
  assert_eq(driver.encode_and_queue(sink, @protocol.Pingresp, None), Ok(()))
  assert_true(
    driver.encode_and_queue(
      sink,
      @protocol.Publish({
        topic: "t",
        payload: b"body",
        qos: @protocol.QoS0,
        packet_id: None,
        dup: false,
        retain: false,
      }),
      None,
    )
    is Err(SlowConsumer),
  )
  state.end_action_scope()
  filler.release().unwrap()
  bus.close()
  assert_eq(ledger.occupied(), 0L)
}

///|
test "decode preflight bounds cover packet metadata and UTF8 without payload copies" {
  let samples : Array[@protocol.Packet] = [
    @protocol.Publish({
      topic: "中😀",
      payload: b"body",
      qos: @protocol.QoS0,
      packet_id: None,
      dup: false,
      retain: false,
    }),
    @protocol.Subscribe({
      packet_id: @protocol.PacketId::new(1).unwrap(),
      subscriptions: [{ topic_filter: "a", requested_qos: @protocol.QoS2 }],
    }),
    @protocol.Connect({
      client_id: "id",
      username: Some("user"),
      password: Some(b"binary\x00"),
      keep_alive: 0,
      clean_session: true,
      will: Some({
        topic: "will",
        payload: b"body",
        qos: @protocol.QoS2,
        retain: false,
      }),
    }),
    @protocol.Pingreq,
  ]
  for packet in samples {
    let encoded = @protocol.encode_packet(packet).unwrap()
    assert_true(decode_cost_bound(encoded) >= packet_cost(packet))
    assert_true(wire_cost_bound(packet) >= encoded.length().to_int64())
  }
}

///|
async test "handshake decision is buffered once for the reader" {
  let accepted = TransportSink::new(1)
  accepted.resolve_handshake(true)
  accepted.resolve_handshake(false)
  assert_true(accepted.wait_handshake())
  accepted.close()

  let rejected = TransportSink::new(1)
  rejected.resolve_handshake(false)
  assert_false(rejected.wait_handshake())
  rejected.close()
}
