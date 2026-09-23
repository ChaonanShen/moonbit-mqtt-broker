///|
/// One logical reservation owns all fixed management infrastructure, request
/// slots and cache overlap. Every category also charges the ordinary global
/// pool and this shared aggregate cap.
pub struct ManagementBudget {
  ledger : @budget.Ledger
  mut parent : @budget.Ticket?
  occupied_slots : Array[Bool]
  mut active : Int
  mut closing : Bool
}

///|
pub struct ManagementRequestLease {
  budget : ManagementBudget
  index : Int
  mut released : Bool
}

///|
pub fn ManagementBudget::maybe_new(
  config : ManagementConfig,
  ledger : @budget.Ledger,
) -> Result[ManagementBudget?, @budget.BudgetError] {
  if !config.enabled() {
    return Ok(None)
  }
  ManagementBudget::new(config, ledger).map(value => Some(value))
}

///|
fn management_pool(
  ledger : @budget.Ledger,
  kind : @budget.ResourceKind,
  limit : Int64,
  cap : @budget.Account,
) -> Result[@budget.Pool, @budget.BudgetError] {
  match ledger.pool(kind, limit) {
    Ok(pool) => pool.with_account(cap)
    Err(error) => Err(error)
  }
}

///|
pub fn ManagementBudget::new(
  config : ManagementConfig,
  ledger : @budget.Ledger,
) -> Result[ManagementBudget, @budget.BudgetError] {
  if !config.enabled() {
    return Err(@budget.InvalidConfiguration)
  }
  let cap = match
    ledger.account(
      @budget.Category,
      config.max_bytes_total(),
      label="management_total",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let infrastructure_pool = match
    management_pool(
      ledger,
      @budget.ManagementInfrastructure,
      config.max_bytes_total(),
      cap,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let request_pool = match
    management_pool(
      ledger,
      @budget.ManagementRequest,
      config.max_bytes_total(),
      cap,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let cache_pool = match
    management_pool(
      ledger,
      @budget.ManagementCache,
      config.max_bytes_total(),
      cap,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // Constructor bounds make these products far below Int64::MAX; use the
  // shared checked helpers anyway, so later bounds cannot silently overflow.
  let sockets = config.max_connections().to_int64()
  let header = config.max_header_bytes().to_int64()
  let response = config.max_response_bytes().to_int64()
  let infrastructure = @budget.checked_add(
    @budget.checked_add(65536L, @budget.checked_mul(512L, sockets).unwrap()).unwrap(),
    32768L,
  ).unwrap()
  let request_slot = @budget.checked_add(
    @budget.checked_add(1024L, @budget.checked_mul(8L, header).unwrap()).unwrap(),
    @budget.checked_mul(4L, response).unwrap(),
  ).unwrap()
  let requests = @budget.checked_mul(sockets, request_slot).unwrap()
  let cache = @budget.checked_mul(
    2L,
    @budget.checked_add(1024L, @budget.checked_mul(8L, response).unwrap()).unwrap(),
  ).unwrap()
  let total = @budget.checked_add(
    @budget.checked_add(infrastructure, requests).unwrap(),
    cache,
  ).unwrap()
  if total != config.required_bytes() || total > config.max_bytes_total() {
    return Err(@budget.InvalidConfiguration)
  }
  let parent = match
    ledger.reserve([
      infrastructure_pool.allocation(infrastructure),
      request_pool.allocation(requests),
      cache_pool.allocation(cache),
    ]) {
    Ok(ticket) => ticket
    Err(error) => return Err(error)
  }
  parent.commit().unwrap()
  Ok({
    ledger,
    parent: Some(parent),
    occupied_slots: Array::make(config.max_connections(), false),
    active: 0,
    closing: false,
  })
}

///|
pub fn ManagementBudget::acquire(
  self : ManagementBudget,
) -> ManagementRequestLease? {
  if self.closing || self.parent is None {
    return None
  }
  for index in 0..<self.occupied_slots.length() {
    if !self.occupied_slots[index] {
      self.occupied_slots[index] = true
      self.active += 1
      return Some({ budget: self, index, released: false })
    }
  }
  None
}

///|
pub fn ManagementRequestLease::release(self : ManagementRequestLease) -> Bool {
  if self.released {
    return false
  }
  self.released = true
  let owner = self.budget
  if !owner.occupied_slots[self.index] {
    return false
  }
  owner.occupied_slots[self.index] = false
  owner.active -= 1
  if owner.closing && owner.active == 0 {
    owner.release_parent()
  }
  true
}

///|
fn ManagementBudget::release_parent(self : ManagementBudget) -> Unit {
  if self.parent is Some(ticket) {
    self.parent = None
    ticket.release().unwrap()
  }
}

///|
/// Stop admission immediately. A slow writer keeps its slot and parent
/// reservation until its real finalizer calls lease.release().
pub fn ManagementBudget::close(self : ManagementBudget) -> Bool {
  self.closing = true
  if self.active == 0 {
    self.release_parent()
    true
  } else {
    false
  }
}

///|
pub fn ManagementBudget::active_count(self : ManagementBudget) -> Int {
  self.active
}

///|
pub fn ManagementBudget::is_closed(self : ManagementBudget) -> Bool {
  self.closing && self.parent is None
}
