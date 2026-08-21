///|
suberror ProbeFailure derive(Debug)

///|
async test "tcp loopback echo repeats without fixed ports" {
  for iteration in 0..<10 {
    @async.with_task_group() <| group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      group.spawn_bg() <| () => {
        let (conn, _) = server.accept()
        defer conn.close()
        let request = conn.read_exactly(1)
        conn.write(request)
      }
      let client = @socket.Tcp::connect(server.addr)
      defer client.close()
      let request = Bytes::from_array([iteration.to_byte()])
      client.write(request)
      assert_eq(client.read_exactly(1), request)
    }
  }
}

///|
async test "bounded queue applies backpressure" {
  let queue = @async.Queue(kind=Blocking(1))
  queue.put(1)
  let second_put_finished = Ref(false)
  @async.with_task_group() <| group => {
    let producer = group.spawn() <| () => {
      queue.put(2)
      second_put_finished.val = true
    }
    @async.sleep(20)
    assert_false(second_put_finished.val)
    assert_eq(queue.get(), 1)
    producer.wait()
    assert_true(second_put_finished.val)
    assert_eq(queue.get(), 2)
    queue.close()
  }
}

///|
async test "queue close wakes blocked producer and consumer" {
  @async.with_task_group() <| group => {
    let full = @async.Queue(kind=Blocking(1))
    full.put(1)
    let producer_woke = Ref(false)
    let producer = group.spawn(allow_failure=true) <| () => {
      full.put(2) catch {
        _ => {
          producer_woke.val = true
          return
        }
      }
      fail("blocked producer unexpectedly completed")
    }
    @async.sleep(20)
    full.close(clear=true)
    producer.wait()
    assert_true(producer_woke.val)

    let empty : @async.Queue[Int] = @async.Queue(kind=Blocking(1))
    let consumer_woke = Ref(false)
    let consumer = group.spawn(allow_failure=true) <| () => {
      ignore(empty.get()) catch {
        _ => {
          consumer_woke.val = true
          return
        }
      }
      fail("blocked consumer unexpectedly completed")
    }
    @async.sleep(20)
    empty.close()
    consumer.wait()
    assert_true(consumer_woke.val)
  }
}

///|
async test "timer and sleeping task cancellation are bounded" {
  let started = @async.now()
  @async.sleep(20)
  let elapsed = @async.now() - started
  assert_true(elapsed >= 10L)
  assert_true(elapsed < 1000L)
  @async.with_task_group() <| group => {
    let sleeper = group.spawn(allow_failure=true) <| () => {
      @async.sleep(30000)
    }
    @async.sleep(10)
    let cancel_started = @async.now()
    sleeper.cancel()
    let cancelled = Ref(false)
    sleeper.wait() catch {
      error => cancelled.val = @async.is_cancellation_error(error)
    }
    assert_true(cancelled.val)
    assert_true(@async.now() - cancel_started < 1000L)
  }
}

///|
async test "cancelling socket read and listener releases tasks" {
  @async.with_task_group() <| group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    let accepted = @async.Queue(kind=Blocking(1))
    let reader = group.spawn(allow_failure=true) <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      accepted.put(true)
      ignore(conn.read_some())
    }
    let client = @socket.Tcp::connect(server.addr)
    defer client.close()
    assert_true(accepted.get())
    let started = @async.now()
    reader.cancel()
    let cancelled = Ref(false)
    reader.wait() catch {
      error => cancelled.val = @async.is_cancellation_error(error)
    }
    server.close()
    accepted.close()
    assert_true(cancelled.val)
    assert_true(@async.now() - started < 1000L)
  }
}

///|
async test "child failure cancels task group sibling" {
  let sibling_cancelled = Ref(false)
  let saw_failure = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg() <| () => { raise ProbeFailure }
    group.spawn_bg() <| () => {
      @async.sleep(30000) catch {
        error => {
          sibling_cancelled.val = @async.is_cancellation_error(error)
          raise error
        }
      }
    }
  }) catch {
    ProbeFailure => saw_failure.val = true
    error => raise error
  }
  assert_true(saw_failure.val)
  assert_true(sibling_cancelled.val)
}

///|
async test "one reader and one writer may share a tcp connection" {
  @async.with_task_group() <| group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    group.spawn_bg() <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      @async.with_task_group() <| connection_group => {
        connection_group.spawn_bg() <| () => { conn.write(b"ping") }
        connection_group.spawn_bg() <| () => {
          assert_eq(conn.read_exactly(4), b"pong")
        }
      }
    }
    let client = @socket.Tcp::connect(server.addr)
    defer client.close()
    @async.with_task_group() <| connection_group => {
      connection_group.spawn_bg() <| () => {
        assert_eq(client.read_exactly(4), b"ping")
      }
      connection_group.spawn_bg() <| () => { client.write(b"pong") }
    }
  }
}
