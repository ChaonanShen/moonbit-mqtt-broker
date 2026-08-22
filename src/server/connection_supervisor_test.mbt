///|
fn supervisor_config() -> ServerConfig {
  let broker = @router.BrokerConfig::new(4, 8, 4).unwrap()
  ServerConfig::new(2, 1024, 1024, 2, 8, 500, 20, broker).unwrap()
}

///|
async test "connection supervisor reports exactly one terminal event" {
  // Reader EOF wins.
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let client = @socket.Tcp::connect(listener.addr)
    let (connection, _) = listener.accept()
    let events = @async.Queue(kind=Blocking(8))
    defer events.close(clear=true)
    let id = ConnectionId::new(71L)
    let supervisor = group.spawn(allow_failure=true) <| () => {
      supervise_connection(connection, id, supervisor_config(), events)
    }
    match events.get() {
      RegisterTransport(register) => assert_eq(register.connection_id, id)
      _ => fail("registration must be the first supervisor event")
    }
    client.close()
    match events.get() {
      Runtime(TransportClosed(closed)) => {
        assert_eq(closed.connection_id, id)
        assert_eq(closed.reason, PeerEof)
      }
      _ => fail("expected exactly one EOF terminal event")
    }
    assert_true(
      events.get() is UnregisterTransport(unregistered) && unregistered == id,
    )
    supervisor.wait()
    assert_true(events.try_get() is None)
  }

  // The independent close signal wins while reader and writer are blocked.
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let (connection, _) = listener.accept()
    let events = @async.Queue(kind=Blocking(8))
    defer events.close(clear=true)
    let id = ConnectionId::new(72L)
    let supervisor = group.spawn(allow_failure=true) <| () => {
      supervise_connection(connection, id, supervisor_config(), events)
    }
    let sink = match events.get() {
      RegisterTransport(register) => register.sink
      _ => fail("registration must expose the transport sink")
    }
    sink.close_signal().put(SlowConsumer)
    match events.get() {
      Runtime(TransportClosed(closed)) => {
        assert_eq(closed.connection_id, id)
        assert_eq(closed.reason, SlowConsumer)
      }
      _ => fail("expected exactly one close-signal terminal event")
    }
    assert_true(
      events.get() is UnregisterTransport(unregistered) && unregistered == id,
    )
    assert_eq(client.read_some(), None)
    supervisor.wait()
    assert_true(events.try_get() is None)
  }

  // A closed socket races reader failure, writer failure, and close signal.
  // Whichever task wins, the supervisor must publish exactly one terminal
  // event and one unregister event for this generation.
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let (connection, _) = listener.accept()
    let events = @async.Queue(kind=Blocking(8))
    defer events.close(clear=true)
    let id = ConnectionId::new(73L)
    let supervisor = group.spawn(allow_failure=true) <| () => {
      supervise_connection(connection, id, supervisor_config(), events)
    }
    let sink = match events.get() {
      RegisterTransport(register) => register.sink
      _ => fail("registration must expose the transport sink")
    }
    connection.close()
    sink.outbound().put(WriteFrame(b"force-write-after-close"))
    sink.close_signal().put(SlowConsumer)
    match events.get() {
      Runtime(TransportClosed(closed)) => {
        assert_eq(closed.connection_id, id)
        assert_true(
          closed.reason == ReadFailure ||
          closed.reason == WriteFailure ||
          closed.reason == SlowConsumer,
        )
      }
      _ => fail("expected one competing terminal event")
    }
    assert_true(
      events.get() is UnregisterTransport(unregistered) && unregistered == id,
    )
    supervisor.wait()
    assert_true(events.try_get() is None)
  }
}

///|
async test "queue close wakes blocked driver and supervisor tasks" {
  // RouterDriver must leave a blocking event get when the global queue closes.
  @async.with_task_group() <| group => {
    let config = supervisor_config()
    let driver = RouterDriver::new(
      BrokerRuntime::new(
        config,
        @router.BrokerState::new(config.broker_config()),
      ),
    )
    let events = @async.Queue(kind=Blocking(1))
    let task = group.spawn(allow_failure=true) <| () => { driver.run(events) }
    @async.pause()
    events.close(clear=true)
    task.wait()
  }

  // Closing both transport queues wakes the blocked writer and closer. The
  // writer reports ServerShutdown, which terminates the blocked reader too.
  @async.with_task_group() <| group => {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let (connection, _) = listener.accept()
    let events = @async.Queue(kind=Blocking(8))
    defer events.close(clear=true)
    let id = ConnectionId::new(74L)
    let supervisor = group.spawn(allow_failure=true) <| () => {
      supervise_connection(connection, id, supervisor_config(), events)
    }
    let sink = match events.get() {
      RegisterTransport(register) => register.sink
      _ => fail("registration must expose the transport sink")
    }
    sink.close()
    match events.get() {
      Runtime(TransportClosed(closed)) => {
        assert_eq(closed.connection_id, id)
        assert_eq(closed.reason, ServerShutdown)
      }
      _ => fail("closed transport queues must terminate the supervisor")
    }
    assert_true(
      events.get() is UnregisterTransport(unregistered) && unregistered == id,
    )
    supervisor.wait()
    assert_true(events.try_get() is None)
    assert_eq(client.read_some(), None)
  }
}
