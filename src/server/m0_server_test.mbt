///|
fn minimal_connect(client_id : String) -> Bytes {
  @protocol.encode_packet(
    @protocol.Packet::Connect({
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
async test "minimal loopback connect receives accepted connack" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    group.spawn_bg() <| () => { serve_one(listener, 1024) }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    client.write(minimal_connect("moonbit-loopback"))
    assert_eq(client.read_exactly(4), b"\x20\x02\x00\x00")
    assert_eq(client.read_some(), None)
  }
}

///|
async test "non connect first packet is closed without connack" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    group.spawn_bg() <| () => { serve_one(listener, 1024) }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    client.write(b"\xc0\x00")
    assert_eq(client.read_some(), None)
  }
}

///|
async test "malformed remaining length is closed" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    group.spawn_bg() <| () => { serve_one(listener, 1024) }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    client.write(b"\x10\x80\x80\x80\x80\x00")
    assert_eq(client.read_some(), None)
  }
}

///|
async test "oversized declaration is rejected before payload" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    group.spawn_bg() <| () => { serve_one(listener, 64) }
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    client.write(b"\x10\x7f")
    assert_eq(client.read_some(), None)
  }
}

///|
async test "truncated connect closes cleanly on peer eof" {
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    group.spawn_bg() <| () => { serve_one(listener, 1024) }
    let client = @socket.Tcp::connect(listener.addr)
    client.write(b"\x10\x20\x00\x04MQ")
    client.close()
  }
}
