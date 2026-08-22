///|
fn resource_config(max_connections? : Int = 32) -> ServerConfig {
  let broker = @router.BrokerConfig::new(8, 64, 8).unwrap()
  ServerConfig::new(max_connections, 1024, 1024, 8, 64, 500, 20, broker).unwrap()
}

///|
fn resource_runtime(config : ServerConfig) -> BrokerRuntime {
  BrokerRuntime::new(config, @router.BrokerState::new(config.broker_config()))
}

///|
fn resource_connect_packet(
  client_id : String,
  keep_alive? : Int = 30,
  will? : @protocol.WillMessage? = None,
) -> @protocol.Packet {
  Connect({
    client_id,
    username: None,
    password: None,
    keep_alive,
    clean_session: true,
    will,
  })
}

///|
async fn resource_connect(
  addr : @socket.Addr,
  packet : @protocol.Packet,
) -> @socket.Tcp {
  let client = @socket.Tcp::connect(addr)
  client.write(@protocol.encode_packet(packet).unwrap())
  client
}

///|
async fn resource_write(
  connection : @socket.Tcp,
  packet : @protocol.Packet,
) -> Unit {
  connection.write(@protocol.encode_packet(packet).unwrap())
}

///|
async fn resource_read(connection : @socket.Tcp) -> @protocol.Packet {
  let bytes : Array[Byte] = [connection.read_exactly(1)[0]]
  let mut multiplier = 1
  let mut remaining = 0
  for _ in 0..<4 {
    let digit = connection.read_exactly(1)[0]
    bytes.push(digit)
    remaining = remaining + (digit.to_int() & 127) * multiplier
    if (digit.to_int() & 128) == 0 {
      break
    }
    multiplier = multiplier * 128
  }
  if remaining > 0 {
    for byte in connection.read_exactly(remaining) {
      bytes.push(byte)
    }
  }
  @protocol.decode_packet(Bytes::from_array(bytes)).unwrap()
}

///|
test "runtime remains deterministic and invariant-safe for 10000 events" {
  let config = resource_config(max_connections=1)
  let first = resource_runtime(config)
  let second = resource_runtime(config)
  let mut event_count = 0
  for index in 0..<2500 {
    let id = ConnectionId::new(index.to_int64() + 1L)
    let client_id = "stress-" + index.to_string()
    let events : Array[RuntimeEvent] = [
      TransportOpened({ connection_id: id, accepted_at_ms: 0L }),
      PacketReceived({
        connection_id: id,
        packet: resource_connect_packet(client_id, keep_alive=0),
        received_at_ms: 1L,
      }),
      PacketReceived({ connection_id: id, packet: Pingreq, received_at_ms: 2L }),
      PacketReceived({
        connection_id: id,
        packet: Disconnect,
        received_at_ms: 3L,
      }),
    ]
    for event in events {
      assert_eq(first.apply(event), second.apply(event))
      assert_eq(first.check_invariants(), Ok(()))
      assert_eq(second.check_invariants(), Ok(()))
      event_count = event_count + 1
    }
  }
  assert_eq(event_count, 10000)
  assert_eq(first.connection_count(), 0)
  assert_eq(first.broker_state().session_count(), 0)
}

///|
async test "twenty concurrent qos0 clients connect ping and disconnect" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = resource_config(max_connections=32)
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, @router.BrokerState::new(config.broker_config()))
    }
    let clients : Array[@socket.Tcp] = []
    for index in 0..<20 {
      clients.push(
        resource_connect(
          listener.addr,
          resource_connect_packet("concurrent-" + index.to_string()),
        ),
      )
    }
    for client in clients {
      assert_true(resource_read(client) is Connack(_))
    }
    for client in clients {
      resource_write(client, Pingreq)
    }
    for client in clients {
      assert_eq(resource_read(client), Pingresp)
    }
    for client in clients {
      resource_write(client, Disconnect)
    }
    for client in clients {
      assert_eq(client.read_some(), None)
      client.close()
    }
    server.cancel()
  }
}

///|
async test "twenty sequential reconnects release connection capacity" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = resource_config(max_connections=1)
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, @router.BrokerState::new(config.broker_config()))
    }
    for index in 0..<20 {
      let client = resource_connect(
        listener.addr,
        resource_connect_packet("reconnect-" + index.to_string()),
      )
      assert_true(resource_read(client) is Connack(_))
      resource_write(client, Disconnect)
      assert_eq(client.read_some(), None)
      client.close()
    }
    server.cancel()
  }
}

///|
async test "network keepalive timeout publishes will at 1.5 times deadline" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = resource_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, @router.BrokerState::new(config.broker_config()))
    }
    let subscriber = resource_connect(
      listener.addr,
      resource_connect_packet("keepalive-observer"),
    )
    defer subscriber.close()
    ignore(resource_read(subscriber))
    resource_write(
      subscriber,
      Subscribe({
        packet_id: @protocol.PacketId::new(1).unwrap(),
        subscriptions: [{ topic_filter: "keepalive/will", requested_qos: QoS0 }],
      }),
    )
    ignore(resource_read(subscriber))
    let will : @protocol.WillMessage = {
      topic: "keepalive/will",
      payload: b"timeout",
      qos: QoS0,
      retain: false,
    }
    let idle = resource_connect(
      listener.addr,
      resource_connect_packet("idle", keep_alive=1, will=Some(will)),
    )
    ignore(resource_read(idle))
    assert_eq(
      resource_read(subscriber),
      Publish({
        topic: "keepalive/will",
        payload: b"timeout",
        qos: QoS0,
        packet_id: None,
        dup: false,
        retain: false,
      }),
    )
    assert_eq(idle.read_some(), None)
    idle.close()
    resource_write(subscriber, Disconnect)
    server.cancel()
  }
}
