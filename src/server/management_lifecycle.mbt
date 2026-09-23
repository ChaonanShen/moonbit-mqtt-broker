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
  query_mailbox : ManagementQueryMailbox?
  command_mailbox : ManagementCommandMailbox?
  operations : @management.OperationTable?
  audit : @management.AuditRing?
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
