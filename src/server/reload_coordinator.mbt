///|
pub(all) struct ReloadStartup {
  config_path : String
  manifest_path : String
  cli_args : Array[String]
  runtime_root : String
  prepare_timeout_ms : Int
  max_source_bytes : Int
  max_generation_bytes : Int64
  max_accounts : Int
  max_acl_rules : Int
  signal_pending : () -> Bool
}

///|
async fn send_reload_control(
  bus : EventBus,
  command : ReloadDriverCommand,
  reply : @async.Queue[ReloadDriverReply],
) -> ReloadDriverReply {
  for ;; {
    if bus.post_reload_control(command) {
      break
    }
    if bus.closed {
      raise ResourceStartupFailure("reload event bus closed")
    }
    @async.sleep(2)
  }
  reply.get() catch {
    _ => raise ResourceStartupFailure("reload driver reply unavailable")
  }
}

///|
async fn signal_reload_once(
  startup : ReloadStartup,
  bus : EventBus,
  generation : GenerationHandle,
  broker : @router.BrokerState,
  strict : StrictPersistenceRuntime?,
  logger : @observability.Logger,
  request : ReloadRequest,
  service : ReloadService,
) -> Unit {
  let active = generation.active()
  let limits = broker.config().resources()
  let pool = broker
    .resource_ledger()
    .pool(Infrastructure, limits.get("max_managed_bytes_total"))
    .unwrap()
  let result = prepare_reload_candidate(
    startup.manifest_path,
    startup.config_path,
    startup.cli_args,
    active.bundle,
    active.effective,
    active.security,
    pool,
    startup.runtime_root,
    startup.prepare_timeout_ms,
    startup.max_source_bytes,
    startup.max_generation_bytes,
    max_accounts=startup.max_accounts,
    max_acl_rules=startup.max_acl_rules,
  )
  match result {
    ReloadNoChange => {
      logger.log(
        @observability.LogRecord::new(
          @async.now(),
          @observability.Info,
          "reload_no_change",
          message="reload request=" + request.id.to_string(),
        ),
      )
      return
    }
    ReloadPrepared(candidate) => {
      let mut transferred = false
      errdefer (if !transferred { candidate.release() })
      service.advance(request, @management.WaitingBarrier, false, None)
      for ;; {
        let reply = @async.Queue(kind=Blocking(1))
        let state = send_reload_control(bus, ReloadEnterBarrier(reply), reply)
        reply.close(clear=true)
        match state {
          ReloadDriverReady => break
          ReloadDriverWaiting => @async.sleep(2)
          _ => raise ResourceStartupFailure("reload barrier rejected")
        }
      }
      let use_wal = strict is Some(_) && candidate.security_changed()
      service.advance(request, @management.Activating, false, None)
      for ;; {
        let reply = @async.Queue(kind=Blocking(if use_wal { 2 } else { 1 }))
        let command = if use_wal {
          ReloadCommitPolicy(candidate, request.base_epoch, reply)
        } else {
          ReloadActivate(candidate, request.base_epoch, reply)
        }
        let state = send_reload_control(bus, command, reply)
        match state {
          ReloadDriverWaiting => {
            reply.close(clear=true)
            @async.sleep(2)
          }
          ReloadDriverStaged => {
            transferred = true
            let outcome = reply.get() catch {
              _ => raise ResourceStartupFailure("reload WAL result unavailable")
            }
            reply.close(clear=true)
            match outcome {
              ReloadDriverActivated(_, _) => break
              ReloadDriverRejected(reason) =>
                raise ResourceStartupFailure("reload activation: " + reason)
              _ => raise ResourceStartupFailure("reload WAL result invalid")
            }
          }
          ReloadDriverActivated(_, _) => {
            transferred = true
            reply.close(clear=true)
            break
          }
          ReloadDriverRejected(reason) => {
            reply.close(clear=true)
            raise ResourceStartupFailure("reload activation: " + reason)
          }
          _ => {
            reply.close(clear=true)
            raise ResourceStartupFailure("reload activation reply invalid")
          }
        }
      }
      service.advance(
        request,
        @management.Reconciling,
        true,
        Some(generation.active().config_epoch()),
      )
      for ;; {
        let reply = @async.Queue(kind=Blocking(1))
        let state = send_reload_control(
          bus,
          ReloadQueryCompletion(generation.active().config_epoch(), reply),
          reply,
        )
        reply.close(clear=true)
        match state {
          ReloadDriverReady => break
          ReloadDriverWaiting => @async.sleep(20)
          ReloadDriverRejected(reason) =>
            raise ResourceStartupFailure("reload reconcile: " + reason)
          _ => raise ResourceStartupFailure("reload reconcile reply invalid")
        }
      }
      service.advance(
        request,
        @management.Retiring,
        true,
        Some(generation.active().config_epoch()),
      )
      logger.log(
        @observability.LogRecord::new(
          @async.now(),
          @observability.Info,
          "reload_completed",
          message="reload request=" +
            request.id.to_string() +
            " config_epoch=" +
            generation.active().config_epoch().to_string(),
        ),
      )
    }
  }
}

///|
/// Polling is independent of management availability and never runs a parser
/// from the signal handler. Each request is serialized until cleanup finishes.
async fn run_reload_signals(
  startup : ReloadStartup,
  bus : EventBus,
  generation : GenerationHandle,
  broker : @router.BrokerState,
  strict : StrictPersistenceRuntime?,
  logger : @observability.Logger,
  shutdown_requested : () -> Bool,
  service : ReloadService,
) -> Unit {
  for ;; {
    @async.sleep(20)
    if shutdown_requested() || bus.closed {
      return
    }
    if (startup.signal_pending)() {
      ignore(service.signal(generation.active().config_epoch()))
    }
    let request = match service.requests.active() {
      Some(value) => value
      None => continue
    }
    if !service.start(request, generation.active().config_epoch()) {
      service.finish(
        request,
        false,
        Some("precondition_failed"),
        generation.active().config_epoch(),
        None,
      )
      continue
    }
    let mut succeeded = true
    signal_reload_once(
      startup, bus, generation, broker, strict, logger, request, service,
    ) catch {
      error => {
        succeeded = false
        logger.log(
          @observability.LogRecord::new(
            @async.now(),
            @observability.Error,
            "reload_failed",
            message="reload request=" + request.id.to_string(),
            reason=error.to_string(),
          ),
        )
      }
    }
    let lsn = match strict {
      Some(runtime) if succeeded &&
        service.activated_epochs.get(request.id) is Some(_) =>
        Some(runtime.coordinator().applied_lsn())
      _ => None
    }
    service.finish(
      request,
      succeeded,
      if succeeded {
        None
      } else {
        Some("reload_failed")
      },
      generation.active().config_epoch(),
      lsn,
    )
  }
}
