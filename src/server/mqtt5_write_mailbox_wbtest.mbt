///|
async test "C-T20 logical offers defer alias choice and let control write first" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let (connection, _) = listener.accept()
    defer connection.close()
    let sink = TransportSink::new(4)
    defer sink.close()
    sink.set_writer_gate(_ => true)
    let connection_id = ConnectionId::new(101L)
    let client_id = @session.ClientId::new("mailbox-client").unwrap()
    for number in [1, 2] {
      let packet : @protocol.PacketV5 = @protocol.Publish5({
        topic: "mailbox/topic",
        payload: b"value",
        qos: @protocol.QoS1,
        packet_id: Some(@protocol.PacketId::new(number).unwrap()),
        dup: false,
        retain: false,
        properties: [],
      })
      let owner : OutboundAuthorization = {
        connection_id,
        client_id,
        session_incarnation: Some(1L),
        delivery_id: Some(number.to_int64()),
        packet_id: Some(@session.SessionPacketId::new(number).unwrap()),
        topic: @topic.TopicName::new("mailbox/topic").unwrap(),
      }
      assert_eq(
        sink.offer_delivery(packet, owner, None, 1024, 4, 4096, None),
        Ok(true),
      )
    }
    assert_true(sink.enqueue_frame(b"\xd0\x00", None, None, priority=true))
    sink.try_close_after_pending(NormalDisconnect)
    let writer = group.spawn(allow_failure=true) <| () => {
      write_transport(ConnectionTransport::plain(connection), sink)
    }
    assert_eq(client.read_exactly(2), b"\xd0\x00")
    let first = @protocol.encode_v5(
      @protocol.Publish5({
        topic: "mailbox/topic",
        payload: b"value",
        qos: @protocol.QoS1,
        packet_id: Some(@protocol.PacketId::new(1).unwrap()),
        dup: false,
        retain: false,
        properties: [{ id: 0x23, value: @protocol.TwoByteValue(1) }],
      }),
      @protocol.ServerToClient,
      1024,
    ).unwrap()
    let second = @protocol.encode_v5(
      @protocol.Publish5({
        topic: "",
        payload: b"value",
        qos: @protocol.QoS1,
        packet_id: Some(@protocol.PacketId::new(2).unwrap()),
        dup: false,
        retain: false,
        properties: [{ id: 0x23, value: @protocol.TwoByteValue(1) }],
      }),
      @protocol.ServerToClient,
      1024,
    ).unwrap()
    assert_eq(client.read_exactly(first.length()), first)
    assert_eq(client.read_exactly(second.length()), second)
    assert_eq(writer.wait(), NormalDisconnect)
    assert_eq(sink.mailbox.offers.length(), 0)
  }
}

///|
test "C-T23 closing a mailbox releases every queued logical offer once" {
  let (bus, state, _) = bus_fixture()
  let sink = TransportSink::new(2)
  ignore(bus.register(ConnectionId::new(201L), sink).unwrap())
  let baseline = state.managed_bytes()
  let owner : OutboundAuthorization = {
    connection_id: ConnectionId::new(201L),
    client_id: @session.ClientId::new("offer-close").unwrap(),
    session_incarnation: Some(1L),
    delivery_id: Some(1L),
    packet_id: Some(@session.SessionPacketId::new(1).unwrap()),
    topic: @topic.TopicName::new("offer/close").unwrap(),
  }
  let packet : @protocol.PacketV5 = @protocol.Publish5({
    topic: "offer/close",
    payload: b"payload",
    qos: @protocol.QoS1,
    packet_id: Some(@protocol.PacketId::new(1).unwrap()),
    dup: false,
    retain: false,
    properties: [],
  })
  assert_eq(
    sink.offer_delivery(packet, owner, None, 1024, 4, 4096, None),
    Ok(true),
  )
  assert_true(state.managed_bytes() > baseline)
  assert_eq(sink.mailbox.offers.length(), 1)
  sink.close()
  sink.close()
  assert_eq(sink.mailbox.offers.length(), 0)
  assert_eq(state.managed_bytes(), baseline)
  bus.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
async test "C-T21 expired logical offer produces one not-started receipt" {
  @async.with_task_group() <| group => {
    let (bus, state, _) = bus_fixture()
    let sink = TransportSink::new(2)
    let connection_id = ConnectionId::new(202L)
    sink.set_writer_gate(_ => true)
    ignore(bus.register(connection_id, sink).unwrap())
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let (connection, _) = listener.accept()
    defer connection.close()
    assert_true(bus.next() is Some(RegisterTransport(_)))
    let owner : OutboundAuthorization = {
      connection_id,
      client_id: @session.ClientId::new("offer-expired").unwrap(),
      session_incarnation: Some(1L),
      delivery_id: Some(91L),
      packet_id: Some(@session.SessionPacketId::new(9).unwrap()),
      topic: @topic.TopicName::new("offer/expired").unwrap(),
    }
    let packet : @protocol.PacketV5 = @protocol.Publish5({
      topic: "offer/expired",
      payload: b"stale",
      qos: @protocol.QoS1,
      packet_id: Some(@protocol.PacketId::new(9).unwrap()),
      dup: false,
      retain: false,
      properties: [{ id: 0x02, value: @protocol.FourByteValue(1U) }],
    })
    let deadline = @session.Deadline::new(@budget.monotonic_ms(), 1000L, 0L).unwrap()
    assert_eq(
      sink.offer_delivery(packet, owner, Some(deadline), 1024, 4, 4096, None),
      Ok(true),
    )
    let writer = group.spawn(allow_failure=true) <| () => {
      write_transport(ConnectionTransport::plain(connection), sink, bus~)
    }
    match bus.next() {
      Some(Accounted(WriteNotStarted(event), ticket)) => {
        assert_eq(event.delivery_id, 91L)
        assert_eq(event.packet_id.value(), 9)
        ticket.release().unwrap()
      }
      _ => fail("expected logical offer receipt")
    }
    sink.close()
    assert_eq(writer.wait(), ServerShutdown)
    connection.close()
    assert_eq(client.read_some(), None)
    bus.close()
    assert_eq(state.managed_bytes(), 0L)
  }
}

///|
test "C-T20 mailbox rejection keeps only the admitted offer budget" {
  let (bus, state, _) = bus_fixture()
  let sink = TransportSink::new(1)
  ignore(bus.register(ConnectionId::new(203L), sink).unwrap())
  let baseline = state.managed_bytes()
  let packet : @protocol.PacketV5 = @protocol.Publish5({
    topic: "offer/full",
    payload: b"x",
    qos: @protocol.QoS1,
    packet_id: Some(@protocol.PacketId::new(1).unwrap()),
    dup: false,
    retain: false,
    properties: [],
  })
  let owner : OutboundAuthorization = {
    connection_id: ConnectionId::new(203L),
    client_id: @session.ClientId::new("offer-full").unwrap(),
    session_incarnation: Some(1L),
    delivery_id: Some(1L),
    packet_id: Some(@session.SessionPacketId::new(1).unwrap()),
    topic: @topic.TopicName::new("offer/full").unwrap(),
  }
  assert_eq(
    sink.offer_delivery(packet, owner, None, 1024, 0, 0, None),
    Ok(true),
  )
  let admitted = state.managed_bytes()
  assert_true(admitted > baseline)
  assert_eq(
    sink.offer_delivery(packet, owner, None, 1024, 0, 0, None),
    Err(SlowConsumer),
  )
  assert_eq(state.managed_bytes(), admitted)
  assert_eq(sink.mailbox.offers.length(), 1)
  sink.close()
  assert_eq(state.managed_bytes(), baseline)
  bus.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
async test "C-T24 partial WS MQTT write closes without installing alias" {
  let (bus, state, _) = bus_fixture()
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  let client = @socket.Tcp::connect(listener.addr)
  defer client.close()
  let (socket, _) = listener.accept()
  defer socket.close()
  let stream_sink = TransportSink::new(2)
  defer stream_sink.close()
  stream_sink.ws_closing = true
  let stream : WebSocketStream = {
    raw: Plain(socket),
    decoder: WebSocketDecoder::new(1024, 2048),
    pending: b"",
    pending_offset: 0,
    deferred_data: [],
    suffix: b"",
    sink: Some(stream_sink),
    receive_pool: None,
    receive_ticket: None,
    bus,
    connection_id: ConnectionId::new(204L),
  }
  let writer_sink = TransportSink::new(2)
  defer writer_sink.close()
  writer_sink.set_writer_gate(_ => true)
  let packet : @protocol.PacketV5 = @protocol.Publish5({
    topic: "partial/alias",
    payload: b"value",
    qos: @protocol.QoS1,
    packet_id: Some(@protocol.PacketId::new(1).unwrap()),
    dup: false,
    retain: false,
    properties: [],
  })
  let owner : OutboundAuthorization = {
    connection_id: ConnectionId::new(204L),
    client_id: @session.ClientId::new("partial-client").unwrap(),
    session_incarnation: Some(1L),
    delivery_id: Some(1L),
    packet_id: Some(@session.SessionPacketId::new(1).unwrap()),
    topic: @topic.TopicName::new("partial/alias").unwrap(),
  }
  assert_eq(
    writer_sink.offer_delivery(packet, owner, None, 1024, 2, 4096, None),
    Ok(true),
  )
  let offer = writer_sink.take_delivery_offer(1L).unwrap()
  assert_eq(
    write_delivery_offer(
      ConnectionTransport::WebSocket(stream),
      writer_sink,
      None,
      offer,
      1000,
    ),
    Some(WriteFailure),
  )
  assert_eq(writer_sink.outbound_aliases.length(), 0)
  assert_eq(writer_sink.pending_outbound_aliases.length(), 0)
  let mqtt = @protocol.encode_v5(
    @protocol.Publish5({
      topic: "partial/alias",
      payload: b"value",
      qos: @protocol.QoS1,
      packet_id: Some(@protocol.PacketId::new(1).unwrap()),
      dup: false,
      retain: false,
      properties: [{ id: 0x23, value: @protocol.TwoByteValue(1) }],
    }),
    @protocol.ServerToClient,
    1024,
  ).unwrap()
  let first_frame = websocket_encode_frame(2, mqtt).unwrap()
  assert_eq(client.read_exactly(first_frame.length()), first_frame)
  bus.close()
  assert_eq(state.managed_bytes(), 0L)
}
