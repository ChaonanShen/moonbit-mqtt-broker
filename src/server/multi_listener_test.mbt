///|
async test "two listeners share the one global connection admission" {
  @async.with_task_group() <| group => {
    let config = loopback_config(max_connections=1)
    let first = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    let second = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer first.close()
    defer second.close()
    let mut stopping = false
    let running = group.spawn(allow_failure=true) <| () => {
      serve_listeners(
        [
          {
            config: ListenerConfig::new("first", first.addr.to_string(), 1).unwrap(),
            socket: first,
          },
          {
            config: ListenerConfig::new("second", second.addr.to_string(), 1).unwrap(),
            socket: second,
          },
        ],
        config,
        loopback_state(config),
        shutdown_requested=() => stopping,
      )
    }
    let client_a = @socket.Tcp::connect(first.addr)
    client_a.write(encoded_connect("listener-a"))
    assert_eq(client_a.read_exactly(4), b"\x20\x02\x00\x00")
    let client_b = @socket.Tcp::connect(second.addr)
    assert_eq(@async.with_timeout(500, () => client_b.read_some()), None)
    client_b.close()
    client_a.close()
    @async.sleep(30)
    let client_c = @socket.Tcp::connect(second.addr)
    client_c.write(encoded_connect("listener-c"))
    assert_eq(client_c.read_exactly(4), b"\x20\x02\x00\x00")
    client_c.close()
    stopping = true
    running.wait()
  }
}

///|
async test "second MQTT bind failure closes the first bound port" {
  let config = loopback_config()
  let reserved = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let probe = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let first_address = probe.addr
  probe.close()
  let first = ListenerConfig::new("first", first_address.to_string(), 2).unwrap()
  let second = ListenerConfig::new("second", reserved.addr.to_string(), 2).unwrap()
  let mut failed = false
  run_listeners([first, second], config, loopback_state(config)) catch {
    _ => failed = true
  }
  assert_true(failed)
  let rebound = @socket.TcpServer(first_address, reuse_addr=true)
  rebound.close()
  reserved.close()
}
