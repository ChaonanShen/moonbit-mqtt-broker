///|
pub(all) struct ManagementStartup {
  config : @management.ManagementConfig
  tokens : @management.TokenDatabase
}

///|
pub(all) enum ManagementStartupError {
  EntropyUnavailable
  BudgetUnavailable
  InvalidLifecycle
} derive(Eq, Debug)

///|
pub struct ManagementAvailability {
  mut details_available : Bool
}

///|

///|
/// Created only after both mandatory listeners are bound. Shutdown cancels
/// and waits for the acceptor and its handlers before close() releases the
/// cache and parent ledger ticket.
pub struct ManagementRuntime {
  listener : @socket.TcpServer
  config : @management.ManagementConfig
  budget : @management.ManagementBudget
  cache : @management.ObservationCache
  http : ManagementHttp
  availability : ManagementAvailability
  mut query_mailbox : ManagementQueryMailbox?
  mut command_mailbox : ManagementCommandMailbox?
  mut operations : @management.OperationTable?
  mut audit : @management.AuditRing?
  mut reload_budget : @budget.Ticket?
  mut pending_kick_reservations : Int
  cursor_table : @management.CursorTable?
  mut mqtt_listener_address : String
  rejections : @management.ManagementRejections
  mut context : ObservationContext
  persistence : PersistenceRuntime?
  mut closed : Bool
}

///|
pub fn ManagementRuntime::new(
  listener : @socket.TcpServer,
  startup : ManagementStartup,
  ledger : @budget.Ledger,
  persistence? : PersistenceRuntime,
) -> Result[ManagementRuntime, ManagementStartupError] {
  let boot_id = match @management.new_boot_id() {
    Some(value) => value
    None => return Err(EntropyUnavailable)
  }
  let started_at = @budget.monotonic_ms()
  if started_at < 0L {
    return Err(EntropyUnavailable)
  }
  let budget = match @management.ManagementBudget::new(startup.config, ledger) {
    Ok(value) => value
    Err(_) => return Err(BudgetUnavailable)
  }
  let cache = match @management.ObservationCache::new(budget) {
    Ok(value) => value
    Err(_) => {
      ignore(budget.close())
      budget.release_b_tables()
      return Err(InvalidLifecycle)
    }
  }
  let rejections = @management.ManagementRejections::new()
  let query_mailbox = if startup.config.details_enabled() {
    Some(ManagementQueryMailbox::new(startup.config.query_queue_limit()))
  } else {
    None
  }
  let command_mailbox = if startup.config.operations_enabled() {
    Some(ManagementCommandMailbox::new(startup.config.operation_queue_limit()))
  } else {
    None
  }
  let operations = if startup.config.operations_enabled() {
    Some(
      @management.OperationTable::new(
        boot_id,
        startup.config.max_operation_records(),
        startup.config.operation_retention_ms().to_int64(),
      ),
    )
  } else {
    None
  }
  let audit = if startup.config.operations_enabled() {
    Some(@management.AuditRing::new(startup.config.max_audit_records()))
  } else {
    None
  }
  let cursor_table = if startup.config.details_enabled() {
    Some(
      @management.CursorTable::new(
        startup.config.max_cursor_records(),
        startup.config.cursor_ttl_ms().to_int64(),
        boot_id,
      ),
    )
  } else {
    None
  }
  let availability : ManagementAvailability = { details_available: false }
  let http = match
    ManagementHttp::new(
      startup.config,
      startup.tokens,
      cache,
      budget,
      rejections,
      boot_id,
      started_at,
      query_mailbox?,
      command_mailbox?,
      availability~,
    ) {
    Ok(value) => value
    Err(_) => {
      cache.close()
      ignore(budget.close())
      budget.release_b_tables()
      return Err(InvalidLifecycle)
    }
  }
  Ok({
    listener,
    config: startup.config,
    budget,
    cache,
    http,
    availability,
    query_mailbox,
    command_mailbox,
    operations,
    audit,
    reload_budget: None,
    pending_kick_reservations: 0,
    cursor_table,
    mqtt_listener_address: "",
    rejections,
    context: {
      boot_id,
      boot_monotonic_ms: started_at,
      lifecycle: @management.ServiceLifecycle::Serving,
      mqtt_listener_up: true,
      management_listener_up: true,
      ready_require_snapshot_healthy: startup.config.ready_require_snapshot_healthy(),
    },
    persistence,
    closed: false,
  })
}

///|
pub async fn ManagementRuntime::run_acceptor(self : ManagementRuntime) -> Unit {
  // The fixed async runtime takes a semaphore before accept, so a TCP flood
  // cannot create unbounded handler tasks ahead of our budget slots.
  self.listener.run_forever(
    max_connections=self.config.max_connections(),
    allow_failure=true,
    (connection, _) => self.http.serve_connection(connection),
  )
}

///|
pub fn ManagementRuntime::mark_stopping(self : ManagementRuntime) -> Unit {
  self.cache.mark_stopping()
  self.context = {
    ..self.context,
    lifecycle: @management.ServiceLifecycle::Stopping,
    mqtt_listener_up: false,
    management_listener_up: false,
  }
}

///|
pub fn ManagementRuntime::close(self : ManagementRuntime) -> Unit {
  if !self.closed {
    self.closed = true
    self.availability.details_available = false
    self.cache.close()
    ignore(self.budget.close())
    self.budget.release_b_tables()
    if self.reload_budget is Some(ticket) {
      ticket.release().unwrap()
      self.reload_budget = None
    }
    self.listener.close()
  }
}

///|
fn ManagementRuntime::set_mqtt_listener_address(
  self : ManagementRuntime,
  address : String,
) -> Unit {
  self.mqtt_listener_address = address
}

///|
/// The reload lifecycle reserves its own bounded command/query path when the
/// B management features are disabled. When B is enabled, both commands share
/// the same OperationTable and audit ring.
fn ManagementRuntime::enable_reload(
  self : ManagementRuntime,
  generation : GenerationHandle,
  ledger : @budget.Ledger,
) -> Unit raise ResourceStartupFailure {
  if self.reload_budget is Some(_) {
    return
  }
  let owns_table = self.operations is None
  let cost = if owns_table {
    self.config.max_operation_records().to_int64() * 2048L +
    self.config.max_audit_records().to_int64() * 512L +
    self.config.operation_queue_limit().to_int64() * 1024L +
    self.config.query_queue_limit().to_int64() * 1024L +
    8192L
  } else {
    65536L
  }
  if cost > self.config.max_bytes_total() {
    raise ResourceStartupFailure("reload management budget exceeds cap")
  }
  let pool = ledger
    .pool(@budget.ManagementInfrastructure, self.config.max_bytes_total())
    .unwrap()
  let ticket = match pool.reserve(cost) {
    Ok(value) => value
    Err(_) =>
      raise ResourceStartupFailure("reload management budget unavailable")
  }
  ticket.commit().unwrap()
  self.reload_budget = Some(ticket)
  if self.operations is None {
    self.operations = Some(
      @management.OperationTable::new(
        self.context.boot_id,
        self.config.max_operation_records(),
        self.config.operation_retention_ms().to_int64(),
      ),
    )
  }
  if self.audit is None {
    self.audit = Some(
      @management.AuditRing::new(self.config.max_audit_records()),
    )
  }
  if self.query_mailbox is None {
    self.query_mailbox = Some(
      ManagementQueryMailbox::new(self.config.query_queue_limit()),
    )
  }
  if self.command_mailbox is None {
    self.command_mailbox = Some(
      ManagementCommandMailbox::new(self.config.operation_queue_limit()),
    )
  }
  self.http.query_mailbox = self.query_mailbox
  self.http.command_mailbox = self.command_mailbox
  self.http.reload_generation = Some(generation)
}
