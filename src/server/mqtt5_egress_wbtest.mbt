///|
test "C-T21 MQTT5 remaining expiry rounds up without restarting the timer" {
  let metadata : @session.MessageMetadata = {
    ..@session.MessageMetadata::empty(),
    expiry: Some(@session.Deadline::new(1000L, 1000L, 1501L).unwrap()),
  }
  assert_eq(mqtt5_message_properties(metadata, 1001L)[0], {
    id: 0x02,
    value: @protocol.FourByteValue(2U),
  })
  assert_eq(mqtt5_message_properties(metadata, 1501L)[0], {
    id: 0x02,
    value: @protocol.FourByteValue(1U),
  })
  assert_eq(mqtt5_message_properties(metadata, 2501L)[0], {
    id: 0x02,
    value: @protocol.FourByteValue(0U),
  })
}

///|
async test "C-T21 expired fresh MQTT5 write reports not started" {
  @async.with_task_group() <| group => {
    let config = ServerConfig::default()
    let state = @router.BrokerState::new(config.broker_config())
    let data : @async.Queue[DriverEvent] = @async.Queue(kind=Blocking(4))
    let bus = EventBus::new(config, state.resource_ledger(), data).unwrap()
    let sink = TransportSink::new(4)
    sink.set_writer_gate(_ => true)
    let id = ConnectionId::new(91L)
    ignore(bus.register(id, sink).unwrap())
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let (connection, _) = listener.accept()
    defer connection.close()
    assert_true(bus.next() is Some(RegisterTransport(_)))
    let packet_id = @protocol.PacketId::new(7).unwrap()
    let packet : @protocol.PacketV5 = @protocol.Publish5({
      topic: "expiry/write",
      payload: b"stale",
      qos: @protocol.QoS1,
      packet_id: Some(packet_id),
      dup: false,
      retain: false,
      properties: [{ id: 0x02, value: @protocol.FourByteValue(1U) }],
    })
    let frame = @protocol.encode_v5(
      packet,
      @protocol.ServerToClient,
      config.max_packet_size(),
    ).unwrap()
    let now_mono_ms = @budget.monotonic_ms()
    let deadline = @session.Deadline::new(now_mono_ms, 1000L, 0L).unwrap()
    let authorization : OutboundAuthorization = {
      connection_id: id,
      client_id: @session.ClientId::new("expiry-writer").unwrap(),
      session_incarnation: Some(1L),
      topic: @topic.TopicName::new("expiry/write").unwrap(),
    }
    assert_true(
      sink.enqueue_frame(
        frame,
        None,
        None,
        authorization~,
        logical_v5=packet,
        expiry_deadline=deadline,
      ),
    )
    let writer = group.spawn(allow_failure=true) <| () => {
      write_transport(ConnectionTransport::plain(connection), sink, bus~)
    }
    let skipped = bus.next()
    match skipped {
      Some(Accounted(WriteNotStarted(event), ticket)) => {
        assert_eq(event.connection_id, id)
        assert_eq(event.packet_id, packet_id)
        assert_eq(event.qos, @protocol.QoS1)
        ticket.release().unwrap()
      }
      _ => fail("expected a write-not-started receipt")
    }
    sink.close()
    assert_eq(writer.wait(), ServerShutdown)
    connection.close()
    assert_eq(client.read_some(), None)
    bus.close()
    data.close(clear=true)
  }
}

///|
test "C-T21 write-not-started receipt releases staged QoS1 state" {
  let base = ServerConfig::default()
  let config : ServerConfig = {
    ..base,
    protocol_config: @config.ProtocolConfig::new(mqtt5_enabled=true).unwrap(),
  }
  let state = @router.BrokerState::new(config.broker_config())
  let runtime = BrokerRuntime::new(config, state)
  let connection_id = ConnectionId::new(95L)
  ignore(runtime.apply(TransportOpened({ connection_id, accepted_at_ms: 1L })))
  let client_id = @session.ClientId::new("writer-expiry").unwrap()
  let accepted = runtime.apply(
    Mqtt5PacketReceived({
      connection_id,
      packet: @protocol.Connect5({
        client_id: client_id.value(),
        username: None,
        password: None,
        keep_alive: 10,
        clean_start: true,
        properties: [],
        will: None,
      }),
      received_at_ms: 2L,
      rx_permit: None,
      rx_error: None,
    }),
  )
  assert_true(accepted.any(action => action is SendMqtt5(_)))
  ignore(
    state
    .apply(
      @router.SubscribeV5({
        client_id,
        entries: [
          {
            filter: @topic.TopicFilter::new("writer/#").unwrap(),
            qos: @session.QoS1,
            no_local: false,
            retain_as_published: false,
            retain_handling: 0,
            subscription_identifier: None,
          },
        ],
      }),
    )
    .unwrap(),
  )
  let metadata : @session.MessageMetadata = {
    ..@session.MessageMetadata::empty(),
    expiry: Some(
      @session.Deadline::from_seconds(@budget.monotonic_ms(), 1000L, 5U).unwrap(),
    ),
  }
  ignore(
    state
    .apply(
      @router.PublishV5({
        publish: {
          origin: @router.Internal,
          topic: @topic.TopicName::new("writer/a").unwrap(),
          payload: b"stale",
          qos: @session.QoS1,
          retain: false,
        },
        metadata,
      }),
    )
    .unwrap(),
  )
  assert_eq(state.pending_qos1_count(), 1)
  let promoted = state.resume_pending()
  let packet_id = match promoted[0] {
    @router.DeliverWithMetadata(item) =>
      @protocol.PacketId::new(item.delivery.packet_id.unwrap().value()).unwrap()
    _ => fail("expected staged MQTT5 PUBLISH")
  }
  assert_eq(state.inflight_count(), 1)
  let actions = runtime.apply(
    WriteNotStarted({
      connection_id,
      client_id,
      session_incarnation: state.policy_session_incarnation(client_id),
      packet_id,
      qos: @protocol.QoS1,
    }),
  )
  assert_eq(state.inflight_count(), 0)
  assert_true(actions.any(action => action is ReleaseV5Credit(_)))
  assert_eq(state.check_invariants(), Ok(()))
}

///|
async test "C-T21 queued MQTT5 PUBLISH is re-encoded with current TTL" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let (connection, _) = listener.accept()
    defer connection.close()
    let sink = TransportSink::new(2)
    defer sink.close()
    let publish : @protocol.PublishV5 = {
      topic: "ttl/write",
      payload: b"value",
      qos: @protocol.QoS0,
      packet_id: None,
      dup: false,
      retain: false,
      properties: [{ id: 0x02, value: @protocol.FourByteValue(3U) }],
    }
    let packet : @protocol.PacketV5 = @protocol.Publish5(publish)
    let frame = @protocol.encode_v5(packet, @protocol.ServerToClient, 1024).unwrap()
    let now_mono_ms = @budget.monotonic_ms()
    let deadline = @session.Deadline::new(now_mono_ms - 2000L, 1000L, 3000L).unwrap()
    assert_true(
      sink.enqueue_frame(
        frame,
        None,
        Some(NormalDisconnect),
        logical_v5=packet,
        expiry_deadline=deadline,
      ),
    )
    let writer = group.spawn(allow_failure=true) <| () => {
      write_transport(ConnectionTransport::plain(connection), sink)
    }
    let bytes = client.read_exactly(frame.length())
    let limits : @protocol.DecodeLimits = {
      max_packet_bytes: 1024,
      max_property_bytes: 1024,
      max_user_properties: 8,
      max_subscription_entries: 8,
    }
    let decoded = @protocol.decode_v5(bytes, @protocol.ServerToClient, limits).unwrap()
    assert_true(
      decoded is @protocol.Publish5(value) &&
      value.properties[0].value == @protocol.FourByteValue(1U),
    )
    assert_eq(writer.wait(), NormalDisconnect)
  }
}
