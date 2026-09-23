///|
async fn run_ticker(
  config : ServerConfig,
  events : @async.Queue[DriverEvent],
  persistence : PersistenceRuntime?,
  bus? : EventBus,
  observation_interval_ms? : Int,
) -> Unit {
  let keep_alive_interval = config.keep_alive_check_interval_ms()
  let auth_interval = config.auth_poll_interval_ms()
  let interval = if keep_alive_interval < auth_interval {
    keep_alive_interval
  } else {
    auth_interval
  }
  let interval = match observation_interval_ms {
    Some(value) if value > 0 && value < interval => value
    _ => interval
  }
  let first_mono = @budget.monotonic_ms()
  let mut next_observation_at : Int64? = match observation_interval_ms {
    Some(value) if value > 0 &&
      first_mono >= 0L &&
      first_mono <= 9223372036854775807L - value.to_int64() =>
      Some(first_mono + value.to_int64())
    _ => None
  }
  let started_at = @async.now()
  let mut next_deadlines_at = started_at + keep_alive_interval.to_int64()
  let mut next_auth_poll_at = started_at + auth_interval.to_int64()
  let mut next_metrics_at = started_at +
    config.system_metrics_interval_ms().to_int64()
  for ;; {
    @async.sleep(interval)
    let now_ms = @async.now()
    if now_ms >= next_deadlines_at {
      match bus {
        Some(bus) => bus.post_tick(CheckDeadlines(now_ms))
        None =>
          events.put(Runtime(CheckDeadlines(now_ms))) catch {
            _ => return
          }
      }
      next_deadlines_at = now_ms + keep_alive_interval.to_int64()
    }
    if now_ms >= next_auth_poll_at {
      match bus {
        Some(bus) => bus.post_tick(AuthenticationPollDue(now_ms))
        None =>
          events.put(Runtime(AuthenticationPollDue(now_ms))) catch {
            _ => return
          }
      }
      next_auth_poll_at = now_ms + auth_interval.to_int64()
    }
    if now_ms >= next_metrics_at {
      let persistence_state = match persistence {
        Some(runtime) => runtime.state()
        None => "disabled"
      }
      match bus {
        Some(bus) =>
          bus.post_tick(EmitSystemMetrics({ now_ms, persistence_state }))
        None =>
          events.put(Runtime(EmitSystemMetrics({ now_ms, persistence_state }))) catch {
            _ => return
          }
      }
      next_metrics_at = now_ms + config.system_metrics_interval_ms().to_int64()
    }
    if next_observation_at is Some(deadline) {
      let current_mono = @budget.monotonic_ms()
      if current_mono >= deadline {
        if bus is Some(active) {
          active.post_observation()
        }
        let observation_delay = observation_interval_ms.unwrap().to_int64()
        next_observation_at = if current_mono < 0L ||
          current_mono > 9223372036854775807L - observation_delay {
          None
        } else {
          Some(current_mono + observation_delay)
        }
      }
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
fn create_auth_executor(
  config : ServerConfig,
  security : @security.SecurityPolicy,
  ledger : @budget.Ledger,
) -> (@security.AuthExecutor, @budget.Ticket)? raise ResourceStartupFailure {
  if !security.has_passwords() {
    return None
  }
  let limits = config.broker_config().resources()
  let infrastructure = ledger
    .pool(Infrastructure, limits.get("max_managed_bytes_total"))
    .unwrap()
  let requests = ledger
    .pool(AuthRequest, limits.get("max_auth_request_bytes_total"))
    .unwrap()
  let results = ledger
    .pool(AuthResult, limits.get("max_auth_result_bytes_total"))
    .unwrap()
  let records = (config.auth_workers() + config.auth_queue_limit()).to_int64()
  let ticket = match
    ledger.reserve([
      infrastructure.allocation(config.auth_workers().to_int64() * 65536L),
      requests.allocation(records * 256L),
      results.allocation(records * 128L),
    ]) {
    Ok(value) => value
    Err(_) =>
      raise ResourceStartupFailure(
        "resource budget cannot initialize authentication executor",
      )
  }
  ticket.commit().unwrap()
  match
    @security.AuthExecutor::new(
      config.auth_workers(),
      config.auth_queue_limit(),
    ) {
    Ok(executor) => Some((executor, ticket))
    Err(_) => {
      ticket.release().unwrap()
      raise ResourceStartupFailure(
        "password authentication executor failed to initialize",
      )
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
  management? : ManagementRuntime,
) -> Unit {
  let events = @async.Queue(kind=Blocking(config.max_runtime_events()))
  let bus = match
    EventBus::new(config, initial_state.resource_ledger(), events) {
    Ok(bus) => bus
    Err(_) =>
      raise ResourceStartupFailure("resource budget cannot initialize server")
  }
  defer bus.close()
  let auth_runtime = create_auth_executor(
    config,
    security,
    initial_state.resource_ledger(),
  )
  let auth_executor = match auth_runtime {
    Some((executor, _)) => Some(executor)
    None => None
  }
  let auth_infrastructure = match auth_runtime {
    Some((_, ticket)) => Some(ticket)
    None => None
  }
  let metrics = BrokerMetrics::new(@async.now())
  let runtime = BrokerRuntime::new(
    config,
    initial_state,
    security~,
    admission=bus.admission,
    metrics~,
    logger~,
    async_auth=auth_executor is Some(_),
  )
  let driver = match persistence {
    Some(value) =>
      RouterDriver::new(
        runtime,
        snapshot=value.driver_config(),
        auth_executor?,
        auth_infrastructure?,
        management?,
      )
    None =>
      RouterDriver::new(
        runtime,
        auth_executor?,
        auth_infrastructure?,
        management?,
      )
  }
  if management is Some(active) && active.config.details_enabled() {
    ignore(driver.enable_management_connection_index(config.max_connections()))
  }
  if management is Some(active) {
    let sample = driver.capture_observation(
      @budget.monotonic_ms(),
      @async.now(),
      active.context,
      persistence?,
    )
    if !active.cache.publish(sample) {
      driver.shutdown_authentication()
      raise ResourceStartupFailure("management initial observation failed")
    }
  }
  let allocator = ConnectionIdAllocator::new()
  errdefer @async.protect_from_cancel(() => driver.shutdown_authentication())
  run_with_snapshot_writer(persistence, driver, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        driver.run_budgeted(bus)
      }
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        let observation_interval_ms = management.map(active => {
          active.config.snapshot_interval_ms()
        })
        run_ticker(config, events, persistence, bus~, observation_interval_ms?)
      }
      let management_task = match management {
        Some(active) => Some(group.spawn(() => active.run_acceptor()))
        None => None
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
        if management is Some(active) {
          active.mark_stopping()
          if management_task is Some(task) {
            task.cancel()
            @async.protect_from_cancel(() => task.wait() catch { _ => () })
          }
          active.listener.close()
        }
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
              if !bus.admission.accept(connection_id, canonical_ip(peer)) {
                connection.close()
                return
              }
              defer bus.admission.release(connection_id)
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
              supervise_transport(
                transport,
                connection_id,
                config,
                events,
                bus~,
              )
            }
          }
        },
      ) catch {
        error => if !shutdown_requested() { raise error }
      }
      if !shutdown_requested() {
        raise ResourceStartupFailure("MQTT listener stopped unexpectedly")
      }
    }
  })
  driver.shutdown_authentication()
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
  let bus = match
    EventBus::new(config, initial_state.resource_ledger(), events) {
    Ok(bus) => bus
    Err(_) =>
      raise ResourceStartupFailure("resource budget cannot initialize server")
  }
  defer bus.close()
  let auth_runtime = create_auth_executor(
    config,
    security,
    initial_state.resource_ledger(),
  )
  let auth_executor = match auth_runtime {
    Some((executor, _)) => Some(executor)
    None => None
  }
  let auth_infrastructure = match auth_runtime {
    Some((_, ticket)) => Some(ticket)
    None => None
  }
  let metrics = BrokerMetrics::new(@async.now())
  let runtime = BrokerRuntime::new(
    config,
    initial_state,
    security~,
    admission=bus.admission,
    metrics~,
    logger~,
    async_auth=auth_executor is Some(_),
  )
  let driver = match persistence {
    Some(value) =>
      RouterDriver::new(
        runtime,
        snapshot=value.driver_config(),
        auth_executor?,
        auth_infrastructure?,
      )
    None => RouterDriver::new(runtime, auth_executor?, auth_infrastructure?)
  }
  errdefer @async.protect_from_cancel(() => driver.shutdown_authentication())
  run_with_snapshot_writer(persistence, driver, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        driver.run_budgeted(bus)
      }
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        run_ticker(config, events, persistence, bus~)
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
      if !bus.admission.accept(ConnectionId::new(1L), canonical_ip(peer)) {
        connection.close()
        return
      }
      defer bus.admission.release(ConnectionId::new(1L))
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
      supervise_transport(
        transport,
        ConnectionId::new(1L),
        config,
        events,
        bus~,
      )
    }
  })
  driver.shutdown_authentication()
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
  management? : ManagementStartup,
) -> Unit {
  defer (match persistence {
    Some(runtime) => runtime.close()
    None => ()
  })
  if once && management is Some(_) {
    raise ResourceStartupFailure(
      "management listener is incompatible with --once",
    )
  }
  let listener = @socket.TcpServer(@socket.Addr::parse(listen), reuse_addr=true)
  defer listener.close()
  let management_runtime = match management {
    None => None
    Some(startup) => {
      if startup.config.details_enabled() &&
        startup.config.index_required_bytes(
          config.broker_config().max_sessions(),
          config.max_connections(),
          config.broker_config().max_subscriptions_total(),
          config.broker_config().max_retained_messages(),
        ) >
        startup.config.max_index_bytes() {
        raise ResourceStartupFailure(
          "management index capacity exceeds max_index_bytes",
        )
      }
      let management_listener = @socket.TcpServer(
        @socket.Addr::parse(startup.config.listen()),
        reuse_addr=true,
      ) catch {
        _ => raise ResourceStartupFailure("management listener bind failed")
      }
      match
        ManagementRuntime::new(
          management_listener,
          startup,
          initial_state.resource_ledger(),
          persistence?,
        ) {
        Ok(value) => Some(value)
        Err(_) => {
          management_listener.close()
          raise ResourceStartupFailure(
            "management listener resources unavailable",
          )
        }
      }
    }
  }
  defer (if management_runtime is Some(active) { active.close() })
  if management_runtime is Some(active) && active.config.details_enabled() {
    ignore(initial_state.enable_management_index())
  }
  let management = management_runtime
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
        management?,
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
        management?,
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
        management?,
      )
    (false, None, None) =>
      serve(
        listener,
        config,
        initial_state,
        shutdown_requested~,
        security~,
        logger~,
        management?,
      )
  }
}
