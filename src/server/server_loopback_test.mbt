///|
fn loopback_config(
  max_connections? : Int = 8,
  max_packet_size? : Int = 1024,
  max_receive_buffer_size? : Int = 0,
  connect_timeout_ms? : Int = 500,
  tick_ms? : Int = 10,
) -> ServerConfig {
  let broker = @router.BrokerConfig::new(8, 64, 8).unwrap()
  let receive_buffer_size = if max_receive_buffer_size == 0 {
    max_packet_size
  } else {
    max_receive_buffer_size
  }
  ServerConfig::new(
    max_connections, max_packet_size, receive_buffer_size, 8, 64, connect_timeout_ms,
    tick_ms, broker,
  ).unwrap()
}

///|
fn loopback_state(config : ServerConfig) -> @router.BrokerState {
  @router.BrokerState::new(config.broker_config())
}

///|
fn encoded_connect(client_id : String) -> Bytes {
  @protocol.encode_packet(
    Connect({
      client_id,
      username: None,
      password: None,
      keep_alive: 30,
      clean_session: true,
      will: None,
    }),
  ).unwrap()
}

///|
async test "loopback drains sticky connect ping and disconnect in order" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    group.spawn_bg() <| () => {
      serve_once(listener, config, loopback_state(config))
    }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let bytes = encoded_connect("sticky").to_array()
    bytes.push(0xc0)
    bytes.push(0x00)
    bytes.push(0xe0)
    bytes.push(0x00)
    client.write(Bytes::from_array(bytes))
    assert_eq(client.read_exactly(6), b"\x20\x02\x00\x00\xd0\x00")
    assert_eq(client.read_some(), None)
  }
}

///|
async test "loopback frame decoder accepts connect one byte at a time" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    group.spawn_bg() <| () => {
      serve_once(listener, config, loopback_state(config))
    }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let frame = encoded_connect("split")
    for index in 0..<frame.length() {
      client.write(Bytes::from_array([frame[index]]))
    }
    assert_eq(client.read_exactly(4), b"\x20\x02\x00\x00")
    client.write(b"\xe0\x00")
    assert_eq(client.read_some(), None)
  }
}

///|
async test "loopback rejects server-direction packet from client" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    group.spawn_bg() <| () => {
      serve_once(listener, config, loopback_state(config))
    }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    client.write(b"\x20\x02\x00\x00")
    assert_eq(client.read_some(), None)
  }
}

///|
async test "loopback handshake timeout closes silent peer" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config(connect_timeout_ms=30, tick_ms=5)
    group.spawn_bg() <| () => {
      serve_once(listener, config, loopback_state(config))
    }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    assert_eq(client.read_some(), None)
  }
}

///|
async test "multi-connection server keeps independent readers and writers" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config()
    let server = group.spawn(allow_failure=true) <| () => {
      serve(listener, config, loopback_state(config))
    }
    let first = @socket.Tcp::connect(listener.addr)
    let second = @socket.Tcp::connect(listener.addr)
    defer first.close()
    defer second.close()
    first.write(encoded_connect("first"))
    second.write(encoded_connect("second"))
    assert_eq(first.read_exactly(4), b"\x20\x02\x00\x00")
    assert_eq(second.read_exactly(4), b"\x20\x02\x00\x00")
    first.write(b"\xc0\x00")
    second.write(b"\xc0\x00")
    assert_eq(first.read_exactly(2), b"\xd0\x00")
    assert_eq(second.read_exactly(2), b"\xd0\x00")
    first.write(b"\xe0\x00")
    second.write(b"\xe0\x00")
    assert_eq(first.read_some(), None)
    assert_eq(second.read_some(), None)
    server.cancel()
  }
}

///|
async test "receive buffer equality preserves a complete packet plus sticky suffix" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config(max_packet_size=16, max_receive_buffer_size=16)
    group.spawn_bg() <| () => {
      serve_once(listener, config, loopback_state(config))
    }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let connect = encoded_connect("a")
    assert_eq(connect.length(), 15)
    let sticky = connect.to_array()
    sticky.push(0xc0)
    sticky.push(0x00)
    client.write(Bytes::from_array(sticky))
    assert_eq(client.read_exactly(6), b"\x20\x02\x00\x00\xd0\x00")
    client.write(b"\xe0\x00")
    assert_eq(client.read_some(), None)
  }
}

///|
async test "receive boundary drains partial prefix before sticky ping" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config(max_packet_size=16, max_receive_buffer_size=16)
    group.spawn_bg() <| () => {
      serve_once(listener, config, loopback_state(config))
    }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let connect = encoded_connect("a")
    client.write(Bytes::from_array(connect.to_array()[0:14].to_owned()))
    let suffix : Array[Byte] = [connect[14], 0xc0, 0x00]
    client.write(Bytes::from_array(suffix))
    assert_eq(client.read_exactly(6), b"\x20\x02\x00\x00\xd0\x00")
    client.write(b"\xe0\x00")
    assert_eq(client.read_some(), None)
  }
}

///|
async test "receive boundary drains multiple sticky control packets in order" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config(max_packet_size=16, max_receive_buffer_size=16)
    group.spawn_bg() <| () => {
      serve_once(listener, config, loopback_state(config))
    }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let sticky = encoded_connect("a").to_array()
    sticky.append([0xc0, 0x00, 0xc0, 0x00])
    client.write(Bytes::from_array(sticky))
    assert_eq(client.read_exactly(8), b"\x20\x02\x00\x00\xd0\x00\xd0\x00")
    client.write(b"\xe0\x00")
    assert_eq(client.read_some(), None)
  }
}

///|
async test "mqtt packet exactly at configured maximum is accepted" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let connect = encoded_connect("a")
    assert_eq(connect.length(), 15)
    let config = loopback_config(max_packet_size=15, max_receive_buffer_size=15)
    group.spawn_bg() <| () => {
      serve_once(listener, config, loopback_state(config))
    }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    client.write(connect)
    assert_eq(client.read_exactly(4), b"\x20\x02\x00\x00")
    client.write(b"\xe0\x00")
    assert_eq(client.read_some(), None)
  }
}

///|
async test "declared mqtt packet over configured maximum closes before payload" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let config = loopback_config(max_packet_size=16, max_receive_buffer_size=16)
    group.spawn_bg() <| () => {
      serve_once(listener, config, loopback_state(config))
    }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    // Remaining Length 15 declares a 17-byte packet, one above the limit.
    client.write(b"\x10\x0f")
    assert_eq(client.read_some(), None)
  }
}
