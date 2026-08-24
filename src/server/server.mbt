///|
async fn run_ticker(
  config : ServerConfig,
  events : @async.Queue[DriverEvent],
  persistence : PersistenceRuntime?,
) -> Unit {
  let mut next_metrics_at = @async.now() +
    config.system_metrics_interval_ms().to_int64()
  for ;; {
    @async.sleep(config.keep_alive_check_interval_ms())
    let now_ms = @async.now()
    events.put(Runtime(CheckDeadlines(now_ms))) catch {
      _ => return
    }
    if now_ms >= next_metrics_at {
      let persistence_state = match persistence {
        Some(runtime) => runtime.state()
        None => "disabled"
      }
      events.put(Runtime(EmitSystemMetrics({ now_ms, persistence_state }))) catch {
        _ => return
      }
      next_metrics_at = now_ms + config.system_metrics_interval_ms().to_int64()
    }
  }
}

///|
async fn wait_for_shutdown(
  check_interval_ms : Int,
  shutdown_requested : () -> Bool,
) -> Unit {
  for ;; {
    @async.sleep(check_interval_ms)
    if shutdown_requested() {
      return
    }
  }
}

///|
pub async fn serve(
  listener : @socket.TcpServer,
  config : ServerConfig,
  initial_state : @router.BrokerState,
  persistence? : PersistenceRuntime,
  shutdown_requested? : () -> Bool = () => false,
  tls? : TlsServerConfig,
  security? : @security.SecurityPolicy = @security.SecurityPolicy::permissive(),
  logger? : @observability.Logger = @observability.Logger::silent(),
) -> Unit {
  let events = @async.Queue(kind=Blocking(config.max_runtime_events()))
  let metrics = BrokerMetrics::new(@async.now())
  let runtime = BrokerRuntime::new(
    config,
    initial_state,
    security~,
    metrics~,
    logger~,
  )
  let driver = match persistence {
    Some(value) => RouterDriver::new(runtime, snapshot=value.driver_config())
    None => RouterDriver::new(runtime)
  }
  let allocator = ConnectionIdAllocator::new()
  defer events.close(clear=true)
  run_with_snapshot_writer(persistence, driver, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        driver.run(events)
      }
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        run_ticker(config, events, persistence)
      }
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        wait_for_shutdown(
          config.keep_alive_check_interval_ms(),
          shutdown_requested,
        )
        logger.log(
          @observability.LogRecord::new(
            @async.now(),
            @observability.Info,
            "shutdown_requested",
            message="broker shutdown requested",
          ),
        )
        listener.close()
        group.return_immediately(())
      }
      listener.run_forever(
        allow_failure=true,
        max_connections=config.max_connections(),
        (connection, peer) => {
          match allocator.allocate() {
            Err(_) => connection.close()
            Ok(connection_id) => {
              let transport = match tls {
                None => ConnectionTransport::plain(connection)
                Some(tls_config) =>
                  ConnectionTransport::secure(connection, tls_config) catch {
                    error => {
                      metrics.record_tls_handshake_failure()
                      logger.log(
                        @observability.LogRecord::new(
                          @async.now(),
                          @observability.Warn,
                          "tls_handshake_failed",
                          message="TLS handshake failed",
                          peer=peer.to_string(),
                          reason=error.to_string(),
                        ),
                      )
                      connection.close()
                      return
                    }
                  }
              }
              supervise_transport(transport, connection_id, config, events)
            }
          }
        },
      ) catch {
        error => if !shutdown_requested() { raise error }
      }
    }
  })
}

///|
pub async fn serve_once(
  listener : @socket.TcpServer,
  config : ServerConfig,
  initial_state : @router.BrokerState,
  persistence? : PersistenceRuntime,
  shutdown_requested? : () -> Bool = () => false,
  tls? : TlsServerConfig,
  security? : @security.SecurityPolicy = @security.SecurityPolicy::permissive(),
  logger? : @observability.Logger = @observability.Logger::silent(),
) -> Unit {
  let events = @async.Queue(kind=Blocking(config.max_runtime_events()))
  let metrics = BrokerMetrics::new(@async.now())
  let runtime = BrokerRuntime::new(
    config,
    initial_state,
    security~,
    metrics~,
    logger~,
  )
  let driver = match persistence {
    Some(value) => RouterDriver::new(runtime, snapshot=value.driver_config())
    None => RouterDriver::new(runtime)
  }
  defer events.close(clear=true)
  run_with_snapshot_writer(persistence, driver, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        driver.run(events)
      }
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        run_ticker(config, events, persistence)
      }
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        wait_for_shutdown(
          config.keep_alive_check_interval_ms(),
          shutdown_requested,
        )
        logger.log(
          @observability.LogRecord::new(
            @async.now(),
            @observability.Info,
            "shutdown_requested",
            message="broker shutdown requested",
          ),
        )
        listener.close()
        group.return_immediately(())
      }
      let (connection, peer) = listener.accept()
      let transport = match tls {
        None => ConnectionTransport::plain(connection)
        Some(tls_config) =>
          ConnectionTransport::secure(connection, tls_config) catch {
            error => {
              metrics.record_tls_handshake_failure()
              logger.log(
                @observability.LogRecord::new(
                  @async.now(),
                  @observability.Warn,
                  "tls_handshake_failed",
                  message="TLS handshake failed",
                  peer=peer.to_string(),
                  reason=error.to_string(),
                ),
              )
              connection.close()
              return
            }
          }
      }
      supervise_transport(transport, ConnectionId::new(1L), config, events)
    }
  })
}

///|
pub async fn run(
  listen : String,
  config : ServerConfig,
  initial_state : @router.BrokerState,
  persistence? : PersistenceRuntime,
  shutdown_requested? : () -> Bool = () => false,
  once? : Bool = false,
  tls? : TlsServerConfig,
  security? : @security.SecurityPolicy = @security.SecurityPolicy::permissive(),
  logger? : @observability.Logger = @observability.Logger::new(),
) -> Unit {
  defer (match persistence {
    Some(runtime) => runtime.close()
    None => ()
  })
  let listener = @socket.TcpServer(@socket.Addr::parse(listen), reuse_addr=true)
  defer listener.close()
  logger.log(
    @observability.LogRecord::new(
      @async.now(),
      @observability.Info,
      "broker_listening",
      message="MQTT broker listening on " + listener.addr.to_string(),
      peer=listener.addr.to_string(),
    ),
  )
  match (once, persistence, tls) {
    (true, Some(runtime), Some(tls_config)) =>
      serve_once(
        listener,
        config,
        initial_state,
        persistence=runtime,
        shutdown_requested~,
        tls=tls_config,
        security~,
        logger~,
      )
    (true, Some(runtime), None) =>
      serve_once(
        listener,
        config,
        initial_state,
        persistence=runtime,
        shutdown_requested~,
        security~,
        logger~,
      )
    (true, None, Some(tls_config)) =>
      serve_once(
        listener,
        config,
        initial_state,
        shutdown_requested~,
        tls=tls_config,
        security~,
        logger~,
      )
    (true, None, None) =>
      serve_once(
        listener,
        config,
        initial_state,
        shutdown_requested~,
        security~,
        logger~,
      )
    (false, Some(runtime), Some(tls_config)) =>
      serve(
        listener,
        config,
        initial_state,
        persistence=runtime,
        shutdown_requested~,
        tls=tls_config,
        security~,
        logger~,
      )
    (false, Some(runtime), None) =>
      serve(
        listener,
        config,
        initial_state,
        persistence=runtime,
        shutdown_requested~,
        security~,
        logger~,
      )
    (false, None, Some(tls_config)) =>
      serve(
        listener,
        config,
        initial_state,
        shutdown_requested~,
        tls=tls_config,
        security~,
        logger~,
      )
    (false, None, None) =>
      serve(
        listener,
        config,
        initial_state,
        shutdown_requested~,
        security~,
        logger~,
      )
  }
}
