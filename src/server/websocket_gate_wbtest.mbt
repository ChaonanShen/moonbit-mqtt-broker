///|
fn gate_client_frame(opcode : Int, body : Bytes) -> Bytes {
  let data : Array[Byte] = [
    (0x80 | opcode).to_byte(),
    (0x80 | body.length()).to_byte(),
    1,
    2,
    3,
    4,
  ]
  for index in 0..<body.length() {
    data.push((body[index].to_int() ^ (index % 4 + 1)).to_byte())
  }
  Bytes::from_array(data)
}

///|
async test "WS auth gate retains buffered data while scheduling Pong" {
  let broker = @router.BrokerConfig::new(8, 64, 8).unwrap()
  let config = ServerConfig::new(8, 1024, 1024, 8, 64, 500, 10, broker).unwrap()
  let state = @router.BrokerState::new(broker)
  let events = @async.Queue(kind=Blocking(8))
  defer events.close(clear=true)
  let bus = EventBus::new(config, state.resource_ledger(), events).unwrap()
  defer bus.close()
  let id = ConnectionId::new(1L)
  assert_true(bus.admission.accept(id, "127.0.0.1"))
  defer bus.admission.release(id)
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  let client = @socket.Tcp::connect(listener.addr)
  defer client.close()
  let (socket, _) = listener.accept()
  let sink = TransportSink::new(8)
  defer sink.close()
  let stream : WebSocketStream = {
    raw: Plain(socket),
    decoder: WebSocketDecoder::new(1024, 2048),
    pending: b"",
    pending_offset: 0,
    deferred_data: [],
    suffix: b"",
    sink: Some(sink),
    receive_pool: None,
    receive_ticket: None,
    bus,
    connection_id: id,
  }
  let input = gate_client_frame(2, b"later").to_array()
  input.append(gate_client_frame(9, b"x").to_array())
  assert_true(stream.decoder.feed(Bytes::from_array(input)))
  let transport = ConnectionTransport::WebSocket(stream)
  assert_eq(transport.drain_buffered_controls(1024), None)
  assert_eq(Bytes::from_array(stream.deferred_data), b"later")
  assert_eq(sink.take_ws_control(), Some(b"\x8a\x01x"))
  transport.close()
}
