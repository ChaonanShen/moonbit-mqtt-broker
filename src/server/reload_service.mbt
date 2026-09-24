///|
pub(all) enum ReloadServiceError {
  ReloadServiceBusy
  ReloadServiceStale
  ReloadServiceCapacity
} derive(Eq, Debug)

///|
pub struct ReloadService {
  requests : ReloadRequests
  operations : @management.OperationTable
  audit : @management.AuditRing
  operation_ids : Map[Int64, String]
  activated_epochs : Map[Int64, Int64]
  boot_id : String
  mode : String
  generation_pool : @budget.Pool
  mut budget : @budget.Ticket?
}

///|
fn ReloadService::new(
  management : ManagementRuntime?,
  ledger : @budget.Ledger,
  mode : String,
  max_generation_bytes? : Int64 = 67108864L,
  infrastructure_limit? : Int64 = 268435456L,
  generation? : GenerationHandle,
) -> ReloadService raise ResourceStartupFailure {
  if max_generation_bytes < 16384L || max_generation_bytes > 268435456L {
    raise ResourceStartupFailure("invalid reload generation account cap")
  }
  let generation_account = match
    ledger.account(
      @budget.Category,
      max_generation_bytes,
      label="reload_generations",
    ) {
    Ok(value) => value
    Err(_) =>
      raise ResourceStartupFailure("reload generation account unavailable")
  }
  let root_pool = ledger.pool(Infrastructure, infrastructure_limit).unwrap()
  let generation_pool = match root_pool.with_account(generation_account) {
    Ok(value) => value
    Err(_) => raise ResourceStartupFailure("reload generation pool unavailable")
  }
  if generation is Some(handle) {
    let current = handle.active()
    let source_bytes = current.bundle
      .sources()
      .fold(init=0L, (total, source) => total + source.bytes.length().to_int64())
    let initial_cost = source_bytes * 3L + 4096L
    let initial_ticket = match generation_pool.reserve(initial_cost) {
      Ok(value) => value
      Err(_) =>
        raise ResourceStartupFailure("initial generation budget unavailable")
    }
    initial_ticket.commit().unwrap()
    if !current.attach_initial_budget(initial_ticket) {
      initial_ticket.release().unwrap()
      raise ResourceStartupFailure("initial generation already accounted")
    }
  }
  let (boot_id, operations, audit, budget) = match management {
    Some(active) =>
      (
        active.context.boot_id,
        active.operations.unwrap(),
        active.audit.unwrap(),
        None,
      )
    None => {
      let boot_id = match @management.new_boot_id() {
        Some(value) => value
        None => raise ResourceStartupFailure("reload boot entropy unavailable")
      }
      let pool = ledger.pool(Infrastructure, 268435456L).unwrap()
      let ticket = match pool.reserve(204800L) {
        Ok(value) => value
        Err(_) =>
          raise ResourceStartupFailure("reload operation budget unavailable")
      }
      ticket.commit().unwrap()
      (
        boot_id,
        @management.OperationTable::new(boot_id, 64, 900000L),
        @management.AuditRing::new(128),
        Some(ticket),
      )
    }
  }
  {
    requests: ReloadRequests::new(true),
    operations,
    audit,
    operation_ids: Map([]),
    activated_epochs: Map([]),
    boot_id,
    mode,
    generation_pool,
    budget,
  }
}

///|
fn ReloadService::close(self : ReloadService) -> Unit {
  if self.budget is Some(ticket) {
    ticket.release().unwrap()
    self.budget = None
  }
}

///|
fn ReloadService::audit_event(
  self : ReloadService,
  request : ReloadRequest,
  phase : String,
  result : String,
  activated : Bool,
  epoch : Int64?,
) -> Unit {
  let record_id = match self.operation_ids.get(request.id) {
    Some(value) => value
    None => return
  }
  let record = match self.operations.get_internal(record_id) {
    Some(value) => value
    None => return
  }
  ignore(
    self.audit.append({
      sequence: 0L,
      timestamp_ms: @async.now(),
      actor_token_id: record.actor_token_id,
      operation_id: record_id,
      kind: @management.Reload,
      target: record.target,
      phase,
      result,
      effect_applied: activated,
      state_revision: epoch,
    }),
  )
}

///|
fn ReloadService::signal(
  self : ReloadService,
  current_epoch : Int64,
) -> ReloadAdmission {
  let admission = self.requests.signal(current_epoch)
  let id = match admission {
    ReloadStarted(value) | ReloadQueued(value) => value
    value => return value
  }
  let now_mono = @budget.monotonic_ms()
  let idempotency_key = self.boot_id[:16].to_owned() + id.to_string()
  let record = self.operations.insert(
    "local_signal",
    @management.Reload,
    current_epoch.to_string(),
    "signal:" + id.to_string(),
    idempotency_key,
    self.mode,
    @async.now(),
    now_mono + 300000L,
  )
  match record {
    Ok(value) => {
      self.operation_ids.set(id, value.id)
      let request = if self.requests.active() is Some(active) && active.id == id {
        active
      } else {
        {
          id,
          source: LocalSignal,
          base_epoch: current_epoch,
          expected_epoch: None,
        }
      }
      self.audit_event(request, "accepted", "accepted", false, None)
      admission
    }
    Err(_) => {
      ignore(self.requests.cancel_unstarted(id))
      ReloadBusy
    }
  }
}

///|
fn ReloadService::admit_http(
  self : ReloadService,
  spec : @management.CommandSpec,
  current_epoch : Int64,
  deadline_ms : Int64,
) -> Result[@management.OperationRecord, ReloadServiceError] {
  let expected = @string.parse_int64(spec.target) catch {
    _ => return Err(ReloadServiceStale)
  }
  if expected != current_epoch {
    return Err(ReloadServiceStale)
  }
  let now = @budget.monotonic_ms()
  let record = match
    self.operations.insert(
      spec.actor_token_id,
      @management.Reload,
      spec.target,
      spec.normalized(),
      spec.idempotency_key,
      self.mode,
      @async.now(),
      now + deadline_ms,
    ) {
    Ok(value) => value
    Err(_) => return Err(ReloadServiceCapacity)
  }
  match self.requests.management(expected, current_epoch) {
    ReloadStarted(id) | ReloadQueued(id) => {
      self.operation_ids.set(id, record.id)
      let request = if self.requests.active() is Some(active) && active.id == id {
        active
      } else {
        {
          id,
          source: Management,
          base_epoch: current_epoch,
          expected_epoch: Some(expected),
        }
      }
      self.audit_event(request, "accepted", "accepted", false, None)
      Ok(record)
    }
    ReloadStale => {
      ignore(self.operations.discard_unstarted(record.id))
      Err(ReloadServiceStale)
    }
    _ => {
      ignore(self.operations.discard_unstarted(record.id))
      Err(ReloadServiceBusy)
    }
  }
}

///|
fn ReloadService::start(
  self : ReloadService,
  request : ReloadRequest,
  current_epoch : Int64,
) -> Bool {
  let id = match self.operation_ids.get(request.id) {
    Some(value) => value
    None => return false
  }
  if !self.requests.can_activate(request.id, current_epoch) {
    return false
  }
  ignore(self.operations.start(id, @management.Preparing, @async.now()))
  self.audit_event(request, "preparing", "running", false, None)
  true
}

///|
fn ReloadService::advance(
  self : ReloadService,
  request : ReloadRequest,
  stage : @management.OperationStage,
  activated : Bool,
  epoch : Int64?,
) -> Unit {
  if self.operation_ids.get(request.id) is Some(id) {
    if activated && epoch is Some(value) {
      self.activated_epochs.set(request.id, value)
    }
    ignore(self.operations.advance_reload(id, stage, activated, epoch))
    self.audit_event(request, "progress", "running", activated, epoch)
  }
}

///|
fn ReloadService::finish(
  self : ReloadService,
  request : ReloadRequest,
  succeeded : Bool,
  error_code : String?,
  current_epoch : Int64,
  committed_lsn : Int64?,
) -> Unit {
  let epoch = self.activated_epochs.get(request.id)
  let activated = epoch is Some(_)
  if self.operation_ids.get(request.id) is Some(id) {
    ignore(
      self.operations.finish(
        id,
        succeeded,
        activated,
        false,
        false,
        error_code,
        epoch,
        None,
        @async.now(),
        @budget.monotonic_ms(),
      ),
    )
    if succeeded && self.mode == "strict" && committed_lsn is Some(lsn) {
      ignore(self.operations.mark_durable_finish(id, lsn))
    }
    self.audit_event(
      request,
      "done",
      if succeeded {
        "succeeded"
      } else {
        "failed"
      },
      activated,
      epoch,
    )
    self.operation_ids.remove(request.id)
    self.activated_epochs.remove(request.id)
  }
  ignore(self.requests.finish_active(request.id, current_epoch))
}
