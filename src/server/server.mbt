///|
async fn run_ticker(
  config : ServerConfig,
  events : @async.Queue[DriverEvent],
  persistence : PersistenceRuntime?,
  strict : StrictPersistenceRuntime?,
  bus? : EventBus,
  observation_interval_ms? : Int,
  management_maintenance? : Bool = false,
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
  let interval = if management_maintenance && interval > 20 {
    20
  } else {
    interval
  }
  let interval = if strict is Some(_) && interval > 2 { 2 } else { interval }
  let first_mono = @budget.monotonic_ms()
  let mut next_maintenance_at = first_mono + 20L
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
    if strict is Some(runtime) && runtime.coordinator().collecting_due() {
      match bus {
        Some(active) => active.post_wal_flush()
        None => ignore(events.try_put(WalFlushDue)) catch { _ => () }
      }
    }
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
      let persistence_state = match strict {
        Some(runtime) => runtime.state()
        None =>
          match persistence {
            Some(runtime) => runtime.state()
            None => "disabled"
          }
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
    if management_maintenance {
      let current_mono = @budget.monotonic_ms()
      if current_mono >= next_maintenance_at {
        if bus is Some(active) {
          active.post_management_maintenance()
        }
        next_maintenance_at = current_mono + 20L
      }
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
  reserve_for_reload? : Bool = false,
) -> (@security.AuthExecutor, @budget.Ticket)? raise ResourceStartupFailure {
  if !security.has_passwords() && !reserve_for_reload {
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
pub async fn serve_listeners(
  listeners : Array[BoundListener],
  config : ServerConfig,
  initial_state : @router.BrokerState,
  persistence? : PersistenceRuntime,
  strict? : StrictPersistenceRuntime,
  shutdown_requested? : () -> Bool = () => false,
  security? : @security.SecurityPolicy = @security.SecurityPolicy::permissive(),
  logger? : @observability.Logger = @observability.Logger::silent(),
  management? : ManagementRuntime,
  material_provider? : TlsMaterialProvider,
  generation? : GenerationHandle,
  reload_enabled? : Bool = false,
  reload_reconcile_items? : Int = 64,
  reload_reconcile_bytes? : Int64 = 1048576L,
  reload? : ReloadStartup,
) -> Unit {
  if reload is Some(_) && generation is None {
    raise ResourceStartupFailure("reload generation unavailable")
  }
  if persistence is Some(_) && strict is Some(_) {
    raise ResourceStartupFailure("snapshot and strict cannot run together")
  }
  for entry in listeners {
    if entry.config.websocket is Some(_) && !websocket_crypto_ready() {
      raise ResourceStartupFailure("WS/WSS requires libcrypto.so.3")
    }
  }
  let events = @async.Queue(kind=Blocking(config.max_runtime_events()))
  let bus = match
    EventBus::new(config, initial_state.resource_ledger(), events) {
    Ok(bus) => bus
    Err(_) =>
      raise ResourceStartupFailure("resource budget cannot initialize server")
  }
  defer bus.close()
  if management is Some(active) && active.query_mailbox is Some(mailbox) {
    bus.attach_management_queries(mailbox)
  }
  if management is Some(active) && active.command_mailbox is Some(mailbox) {
    bus.attach_management_commands(mailbox)
  }
  let reload_service : ReloadService? = if reload is Some(_) {
    Some(
      ReloadService::new(
        management,
        initial_state.resource_ledger(),
        if strict is Some(_) {
          "strict"
        } else if persistence is Some(_) {
          "snapshot"
        } else {
          "off"
        },
      ),
    )
  } else {
    None
  }
  defer (if reload_service is Some(value) { value.close() })
  let auth_runtime = create_auth_executor(
    config,
    security,
    initial_state.resource_ledger(),
    reserve_for_reload=reload_enabled,
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
    initial_policy_epoch=generation
      .map(value => value.active().policy_epoch())
      .unwrap_or(0L),
  )
  let strict_coordinator = strict.map(value => value.coordinator())
  let strict_generations = strict
    .map(value => value.generations())
    .unwrap_or(Map([]))
  let driver = match persistence {
    Some(value) =>
      RouterDriver::new(
        runtime,
        snapshot=value.driver_config(),
        auth_executor?,
        auth_infrastructure?,
        management?,
        strict?=strict_coordinator,
        strict_generations~,
        generation?,
        material_provider?,
        reload_reconcile_items~,
        reload_reconcile_bytes~,
        reload_service?,
      )
    None =>
      RouterDriver::new(
        runtime,
        auth_executor?,
        auth_infrastructure?,
        management?,
        strict?=strict_coordinator,
        strict_generations~,
        generation?,
        material_provider?,
        reload_reconcile_items~,
        reload_reconcile_bytes~,
        reload_service?,
      )
  }
  if management is Some(active) && active.config.details_enabled() {
    ignore(driver.enable_management_connection_index(config.max_connections()))
  }
  if management is Some(active) {
    active.availability.details_available = active.config.details_enabled() &&
      initial_state.management_index_available() &&
      driver.management_connection_index_available()
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
  errdefer @async.protect_from_cancel(() => {
    driver.shutdown_authentication()
    driver.shutdown_management(bus)
  })
  run_with_persistence_writers(persistence, strict, driver, bus, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        driver.run_budgeted(bus)
      }
      if reload is Some(startup) && generation is Some(handle) {
        group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
          run_reload_signals(
            startup,
            bus,
            handle,
            initial_state,
            strict,
            logger,
            shutdown_requested,
            reload_service.unwrap(),
          )
        }
      }
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        let observation_interval_ms = management.map(active => {
          active.config.snapshot_interval_ms()
        })
        let maintenance = management is Some(active) &&
          active.config.details_enabled()
        run_ticker(
          config,
          events,
          persistence,
          strict,
          bus~,
          observation_interval_ms?,
          management_maintenance=maintenance,
        )
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
        for entry in listeners {
          entry.socket.close()
        }
        group.return_immediately(())
      }
      for entry in listeners {
        group.spawn_bg() <| () => {
          entry.socket.run_forever(
            allow_failure=true,
            max_connections=entry.config.max_connections,
            (connection, peer) => {
              match allocator.allocate() {
                Err(_) => connection.close()
                Ok(connection_id) => {
                  if !bus.admission.accept(connection_id, canonical_ip(peer)) {
                    connection.close()
                    return
                  }
                  defer bus.admission.release(connection_id)
                  let material = match material_provider {
                    Some(provider) => provider.acquire(entry.config.id)
                    None => None
                  }
                  defer (if material is Some(lease) { lease.release() })
                  if material_provider is Some(_) &&
                    entry.config.tls is Some(_) &&
                    material is None {
                    connection.close()
                    return
                  }
                  let transport = match entry.config.tls {
                    None => ConnectionTransport::plain(connection)
                    Some(original_config) => {
                      let tls_config = match material {
                        Some(lease) => lease.config
                        None => original_config
                      }
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
                              listener_id=entry.config.id,
                              transport=entry.config.transport,
                              reason=error.to_string(),
                            ),
                          )
                          connection.close()
                          return
                        }
                      }
                    }
                  }
                  let transport = match entry.config.websocket {
                    None => transport
                    Some(policy) => {
                      let limits = config.broker_config().resources()
                      let pool = bus.ledger
                        .pool(Receive, limits.get("max_receive_bytes_total"))
                        .unwrap()
                      let ticket = match
                        pool.reserve(
                          (policy.max_header_bytes + 4096).to_int64() * 3L,
                        ) {
                        Ok(value) => value
                        Err(_) => {
                          transport.close()
                          return
                        }
                      }
                      defer ticket.release().unwrap()
                      transport.upgrade(policy, bus, connection_id) catch {
                        error => {
                          logger.log(
                            @observability.LogRecord::new(
                              @async.now(),
                              @observability.Warn,
                              "websocket_upgrade_failed",
                              peer=peer.to_string(),
                              listener_id=entry.config.id,
                              transport=entry.config.transport,
                              reason=error.to_string(),
                            ),
                          )
                          transport.close()
                          return
                        }
                      }
                    }
                  }
                  supervise_transport(
                    transport,
                    connection_id,
                    config,
                    events,
                    bus~,
                    listener_id=entry.config.id,
                    transport_name=entry.config.transport,
                    logger~,
                  )
                }
              }
            },
          ) catch {
            error => if !shutdown_requested() { raise error }
          }
          if !shutdown_requested() {
            raise ResourceStartupFailure(
              "MQTT listener " + entry.config.id + " stopped unexpectedly",
            )
          }
        }
      }
    }
  })
  if strict is None {
    driver.shutdown_authentication()
  }
}

///|
pub async fn serve(
  listener : @socket.TcpServer,
  config : ServerConfig,
  initial_state : @router.BrokerState,
  persistence? : PersistenceRuntime,
  strict? : StrictPersistenceRuntime,
  shutdown_requested? : () -> Bool = () => false,
  tls? : TlsServerConfig,
  security? : @security.SecurityPolicy = @security.SecurityPolicy::permissive(),
  logger? : @observability.Logger = @observability.Logger::silent(),
  management? : ManagementRuntime,
) -> Unit {
  let entry = ListenerConfig::new(
    "mqtt",
    listener.addr.to_string(),
    config.max_connections(),
    tls?,
  ).unwrap()
  serve_listeners(
    [{ config: entry, socket: listener }],
    config,
    initial_state,
    persistence?,
    strict?,
    shutdown_requested~,
    security~,
    logger~,
    management?,
  )
}

///|
pub async fn serve_once(
  listener : @socket.TcpServer,
  config : ServerConfig,
  initial_state : @router.BrokerState,
  persistence? : PersistenceRuntime,
  strict? : StrictPersistenceRuntime,
  shutdown_requested? : () -> Bool = () => false,
  tls? : TlsServerConfig,
  websocket? : WebSocketPolicy,
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
  let strict_coordinator = strict.map(value => value.coordinator())
  let strict_generations = strict
    .map(value => value.generations())
    .unwrap_or(Map([]))
  let driver = match persistence {
    Some(value) =>
      RouterDriver::new(
        runtime,
        snapshot=value.driver_config(),
        auth_executor?,
        auth_infrastructure?,
        strict?=strict_coordinator,
        strict_generations~,
      )
    None =>
      RouterDriver::new(
        runtime,
        auth_executor?,
        auth_infrastructure?,
        strict?=strict_coordinator,
        strict_generations~,
      )
  }
  errdefer @async.protect_from_cancel(() => driver.shutdown_authentication())
  run_with_persistence_writers(persistence, strict, driver, bus, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        driver.run_budgeted(bus)
      }
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        run_ticker(config, events, persistence, strict, bus~)
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
      let transport = match websocket {
        None => transport
        Some(policy) => {
          if !websocket_crypto_ready() {
            transport.close()
            return
          }
          let limits = config.broker_config().resources()
          let pool = bus.ledger
            .pool(Receive, limits.get("max_receive_bytes_total"))
            .unwrap()
          let ticket = match
            pool.reserve((policy.max_header_bytes + 4096).to_int64() * 3L) {
            Ok(value) => value
            Err(_) => {
              transport.close()
              return
            }
          }
          defer ticket.release().unwrap()
          transport.upgrade(policy, bus, ConnectionId::new(1L)) catch {
            _ => {
              transport.close()
              return
            }
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
  if strict is None {
    driver.shutdown_authentication()
  }
  driver.shutdown_management(bus)
}

///|
pub async fn run_listeners(
  listeners : Array[ListenerConfig],
  config : ServerConfig,
  initial_state : @router.BrokerState,
  persistence? : PersistenceRuntime,
  strict? : StrictPersistenceRuntime,
  shutdown_requested? : () -> Bool = () => false,
  once? : Bool = false,
  security? : @security.SecurityPolicy = @security.SecurityPolicy::permissive(),
  logger? : @observability.Logger = @observability.Logger::new(),
  management? : ManagementStartup,
  reload_tls? : (
    @bundle.CapturedBundle,
    @bundle.ReloadEffectiveCandidate,
    String,
  ),
  reload_enabled? : Bool = false,
  reload_reconcile_items? : Int = 64,
  reload_reconcile_bytes? : Int64 = 1048576L,
  reload? : ReloadStartup,
) -> Unit {
  defer (match persistence {
    Some(runtime) => runtime.close()
    None => ()
  })
  defer (if strict is Some(runtime) { runtime.close() })
  if once && management is Some(_) {
    raise ResourceStartupFailure(
      "management listener is incompatible with --once",
    )
  }
  if listeners.length() < 1 || listeners.length() > 16 {
    raise ResourceStartupFailure("MQTT listener count must be in 1..16")
  }
  if once && listeners.length() != 1 {
    raise ResourceStartupFailure("--once requires exactly one MQTT listener")
  }
  for entry in listeners {
    if entry.websocket is Some(_) && !websocket_crypto_ready() {
      raise ResourceStartupFailure("WS/WSS requires libcrypto.so.3")
    }
  }
  let ids : Map[String, Bool] = Map([])
  for entry in listeners {
    if ids.contains(entry.id) {
      raise ResourceStartupFailure("duplicate MQTT listener ID: " + entry.id)
    }
    ids.set(entry.id, true)
    if entry.max_connections > config.max_connections() {
      raise ResourceStartupFailure(
        "MQTT listener cap exceeds global cap: " + entry.id,
      )
    }
  }
  let materials = TlsMaterialProvider::new()
  let generation : GenerationHandle? = match reload_tls {
    Some((bundle, candidate, _)) => {
      let fingerprint = bundle.policy_fingerprint(candidate) catch {
        _ =>
          raise ResourceStartupFailure("initial policy fingerprint unavailable")
      }
      let policy_epoch = match strict {
        Some(runtime) =>
          runtime
          .coordinator()
          .policy_state()
          .map(value => value.sequence)
          .unwrap_or(0L)
        None => 0L
      }
      Some(
        GenerationHandle::new(
          ConfigGeneration::initial(
            bundle,
            candidate,
            security,
            fingerprint,
            policy_epoch~,
          ),
        ),
      )
    }
    None => None
  }
  defer (if generation is Some(value) { value.close() })
  let prepared_tls : PreparedTlsGeneration? = match reload_tls {
    None => None
    Some((bundle, candidate, root)) => {
      let limits = config.broker_config().resources()
      let pool = initial_state
        .resource_ledger()
        .pool(Infrastructure, limits.get("max_managed_bytes_total"))
        .unwrap()
      Some(prepare_tls_generation(bundle, candidate, pool, root))
    }
  }
  defer (if prepared_tls is Some(value) { value.release() })
  let expected_tls_ids : Array[String] = []
  for entry in listeners {
    if entry.tls is Some(_) {
      expected_tls_ids.push(entry.id)
    }
  }
  if prepared_tls is Some(value) &&
    !value.install_initial(materials, expected_tls_ids) {
    raise ResourceStartupFailure("prepared TLS listener set mismatch")
  }
  let material_tickets : Array[@budget.Ticket] = []
  defer (for ticket in material_tickets {
    ticket.release().unwrap()
  })
  defer materials.close()
  let prepared : Array[ListenerConfig] = []
  for entry in listeners {
    match entry.tls {
      None => prepared.push(entry)
      Some(tls) => {
        if prepared_tls is Some(_) {
          let captured_config = match materials.current_config(entry.id) {
            Some(value) => value
            None =>
              raise ResourceStartupFailure("prepared TLS listener missing")
          }
          prepared.push(
            ListenerConfig::new(
              entry.id,
              entry.listen,
              entry.max_connections,
              tls=captured_config,
              transport=entry.transport,
              websocket?=entry.websocket,
            ).unwrap(),
          )
          continue
        }
        let limits = config.broker_config().resources()
        let pool = initial_state
          .resource_ledger()
          .pool(Infrastructure, limits.get("max_managed_bytes_total"))
          .unwrap()
        let ticket = match pool.reserve(2097152L + 4096L) {
          Ok(value) => value
          Err(_) =>
            raise ResourceStartupFailure(
              "TLS material snapshot budget unavailable: " + entry.id,
            )
        }
        ticket.commit().unwrap()
        material_tickets.push(ticket)
        let lease = TlsMaterialLease::capture(tls)
        materials.add_initial(entry.id, lease)
        validate_tls_config(lease.config) catch {
          _ =>
            raise ResourceStartupFailure(
              "TLS material snapshot validation failed: " + entry.id,
            )
        }
        prepared.push(
          ListenerConfig::new(
            entry.id,
            entry.listen,
            entry.max_connections,
            tls=lease.config,
            transport=entry.transport,
            websocket?=entry.websocket,
          ).unwrap(),
        )
      }
    }
  }
  let bound : Array[BoundListener] = []
  defer (for entry in bound {
    entry.socket.close()
  })
  for entry in prepared {
    let socket = @socket.TcpServer(
      @socket.Addr::parse(entry.listen),
      reuse_addr=true,
    ) catch {
      error =>
        raise ResourceStartupFailure(
          "MQTT listener " + entry.id + " bind failed: " + error.to_string(),
        )
    }
    bound.push({ config: entry, socket })
  }
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
  if reload is Some(_) &&
    management_runtime is Some(active) &&
    generation is Some(handle) {
    active.enable_reload(handle, initial_state.resource_ledger())
  }
  if management_runtime is Some(active) {
    active.set_mqtt_listener_address(bound[0].socket.addr.to_string())
  }
  if management_runtime is Some(active) && active.config.details_enabled() {
    ignore(initial_state.enable_management_index())
  }
  for entry in bound {
    logger.log(
      @observability.LogRecord::new(
        @async.now(),
        @observability.Info,
        "broker_listening",
        message="MQTT broker listening on " + entry.socket.addr.to_string(),
        peer=entry.socket.addr.to_string(),
        listener_id=entry.config.id,
        transport=entry.config.transport,
      ),
    )
  }
  if once {
    let first = bound[0]
    serve_once(
      first.socket,
      config,
      initial_state,
      persistence?,
      strict?,
      shutdown_requested~,
      tls?=first.config.tls,
      websocket?=first.config.websocket,
      security~,
      logger~,
    )
  } else {
    serve_listeners(
      bound,
      config,
      initial_state,
      persistence?,
      strict?,
      shutdown_requested~,
      security~,
      logger~,
      management?=management_runtime,
      material_provider=materials,
      generation?,
      reload_enabled~,
      reload_reconcile_items~,
      reload_reconcile_bytes~,
      reload?,
    )
  }
}

///|
pub async fn run(
  listen : String,
  config : ServerConfig,
  initial_state : @router.BrokerState,
  persistence? : PersistenceRuntime,
  strict? : StrictPersistenceRuntime,
  shutdown_requested? : () -> Bool = () => false,
  once? : Bool = false,
  tls? : TlsServerConfig,
  security? : @security.SecurityPolicy = @security.SecurityPolicy::permissive(),
  logger? : @observability.Logger = @observability.Logger::new(),
  management? : ManagementStartup,
) -> Unit {
  let listener = ListenerConfig::new(
    "mqtt",
    listen,
    config.max_connections(),
    tls?,
  ).unwrap()
  run_listeners(
    [listener],
    config,
    initial_state,
    persistence?,
    strict?,
    shutdown_requested~,
    once~,
    security~,
    logger~,
    management?,
  )
}
