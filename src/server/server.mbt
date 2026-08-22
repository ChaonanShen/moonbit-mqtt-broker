///|
async fn run_ticker(
  config : ServerConfig,
  events : @async.Queue[DriverEvent],
) -> Unit {
  for ;; {
    @async.sleep(config.keep_alive_check_interval_ms())
    events.put(Runtime(CheckDeadlines(@async.now()))) catch {
      _ => return
    }
  }
}

///|
pub async fn serve(
  listener : @socket.TcpServer,
  config : ServerConfig,
  initial_state : @router.BrokerState,
) -> Unit {
  let events = @async.Queue(kind=Blocking(config.max_runtime_events()))
  let runtime = BrokerRuntime::new(config, initial_state)
  let driver = RouterDriver::new(runtime)
  let allocator = ConnectionIdAllocator::new()
  defer events.close(clear=true)
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
      driver.run(events)
    }
    group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
      run_ticker(config, events)
    }
    listener.run_forever(
      allow_failure=true,
      max_connections=config.max_connections(),
      (connection, _) => {
        match allocator.allocate() {
          Err(_) => connection.close()
          Ok(connection_id) =>
            supervise_connection(connection, connection_id, config, events)
        }
      },
    )
  }
}

///|
pub async fn serve_once(
  listener : @socket.TcpServer,
  config : ServerConfig,
  initial_state : @router.BrokerState,
) -> Unit {
  let events = @async.Queue(kind=Blocking(config.max_runtime_events()))
  let runtime = BrokerRuntime::new(config, initial_state)
  let driver = RouterDriver::new(runtime)
  defer events.close(clear=true)
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
      driver.run(events)
    }
    group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
      run_ticker(config, events)
    }
    let (connection, _) = listener.accept()
    supervise_connection(connection, ConnectionId::new(1L), config, events)
  }
}

///|
pub async fn run(
  listen : String,
  config : ServerConfig,
  initial_state : @router.BrokerState,
  once? : Bool = false,
) -> Unit {
  let listener = @socket.TcpServer(@socket.Addr::parse(listen), reuse_addr=true)
  defer listener.close()
  println("MQTT broker listening on " + listener.addr.to_string())
  if once {
    serve_once(listener, config, initial_state)
  } else {
    serve(listener, config, initial_state)
  }
}
