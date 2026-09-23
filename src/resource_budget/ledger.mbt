///|
pub(all) enum ResourceKind {
  Receive
  RuntimeEvent
  Inflight
  Pending
  InboundQoS2
  Retained
  Will
  Subscription
  SessionMetadata
  Outbound
  Routing
  Snapshot
  AuthRequest
  AuthWorkspace
  AuthResult
  ConnectionMetadata
  LimiterMetadata
  Infrastructure
  ControlEvent
  ControlRuntime
  ControlFrame
  ControlWork
  ManagementInfrastructure
  ManagementRequest
  ManagementCache
  ManagementIndex
  ManagementQuery
  ManagementCursor
  ManagementOperation
  ManagementAudit
} derive(Eq, Hash, Debug)

///|
pub struct Account {
  authority : Array[Int]
  id : Int64
  label : String
  scope : LimitScope
  limit : Int64
  priv mut committed : Int64
  priv mut reserved : Int64
}

///|
pub struct Ledger {
  authority : Array[Int]
  total : Account
  ordinary : Account
  control : Account
  rejections : Map[String, Int64]
  categories : Map[ResourceKind, Account]
  priv mut next_id : Int64
  priv mut live_tickets : Int
  max_tickets : Int
}

///|
pub struct Pool {
  ledger : Ledger
  kind : ResourceKind
  accounts : Array[Account]
}

///|
pub struct Allocation {
  pool : Pool
  bytes : Int64
}

///|
priv struct Charge {
  account : Account
  mut bytes : Int64
}

///|
priv enum TicketState {
  Reserved
  Committed
  Released
} derive(Eq)

///|
pub struct Ticket {
  ledger : Ledger
  priv mut charges : Array[Charge]
  priv mut state : TicketState
  priv mut busy : Bool
}

///|
pub fn Ledger::new(
  total : Int64,
  control : Int64,
  max_tickets? : Int = 65536,
) -> Result[Ledger, BudgetError] {
  if total < 0L || control < 0L || control > total || max_tickets < 1 {
    return Err(InvalidConfiguration)
  }
  let authority = [0]
  Ok({
    authority,
    total: {
      authority,
      id: 0L,
      label: "managed",
      scope: Global,
      limit: total,
      committed: 0L,
      reserved: 0L,
    },
    ordinary: {
      authority,
      id: 1L,
      label: "ordinary",
      scope: Global,
      limit: total - control,
      committed: 0L,
      reserved: 0L,
    },
    control: {
      authority,
      id: 2L,
      label: "control",
      scope: Control,
      limit: control,
      committed: 0L,
      reserved: 0L,
    },
    rejections: Map([]),
    categories: Map([]),
    next_id: 3L,
    live_tickets: 0,
    max_tickets,
  })
}

///|
pub fn Ledger::account(
  self : Ledger,
  scope : LimitScope,
  limit : Int64,
  label? : String = "scope",
) -> Result[Account, BudgetError] {
  if limit < 0L {
    return Err(InvalidConfiguration)
  }
  if self.next_id == 9223372036854775807L {
    return Err(Overflow)
  }
  let id = self.next_id
  self.next_id += 1L
  Ok({
    authority: self.authority,
    id,
    scope,
    label,
    limit,
    committed: 0L,
    reserved: 0L,
  })
}

///|
/// A category has one authority per ledger. Repeated creation cannot bypass it.
pub fn Ledger::pool(
  self : Ledger,
  kind : ResourceKind,
  limit : Int64,
) -> Result[Pool, BudgetError] {
  let category = match self.categories.get(kind) {
    Some(account) => {
      if account.limit != limit {
        return Err(InvalidConfiguration)
      }
      account
    }
    None => {
      let account = match self.account(Category, limit, label=kind.name()) {
        Ok(a) => a
        Err(e) => return Err(e)
      }
      self.categories.set(kind, account)
      account
    }
  }
  let partition = if kind == ControlEvent ||
    kind == ControlRuntime ||
    kind == ControlFrame ||
    kind == ControlWork {
    self.control
  } else {
    self.ordinary
  }
  let pool = Pool::{
    ledger: self,
    kind,
    accounts: [self.total, partition, category],
  }
  Ok(pool)
}

///|
/// Attach an aggregate local cap shared by several categories (e.g. session state).
/// Account identity is checked when composing allocations; callers use this ledger's accounts.
pub fn Pool::with_account(
  self : Pool,
  account : Account,
) -> Result[Pool, BudgetError] {
  if !physical_equal(self.ledger.authority, account.authority) {
    return Err(ForeignAccount)
  }
  if self.accounts.length() >= 8 || self.accounts.any(a => a.id == account.id) {
    return Err(InvalidConfiguration)
  }
  let accounts = self.accounts.copy()
  accounts.push(account)
  Ok({ ..self, accounts, })
}

///|
pub fn Pool::allocation(self : Pool, bytes : Int64) -> Allocation {
  { pool: self, bytes }
}

///|
fn Ledger::aggregate(
  self : Ledger,
  allocations : Array[Allocation],
) -> Result[Array[Charge], BudgetError] {
  if allocations.length() > 65536 {
    return Err(InvalidConfiguration)
  }
  if allocations.length() == 1 {
    let allocation = allocations[0]
    if !physical_equal(allocation.pool.ledger, self) {
      return Err(ForeignAccount)
    }
    if allocation.bytes < 0L {
      return Err(InvalidAmount)
    }
    return Ok(
      allocation.pool.accounts.map(account => Charge::{
        account,
        bytes: allocation.bytes,
      }),
    )
  }
  let charges : Map[Int64, Charge] = Map([])
  for allocation in allocations {
    if !physical_equal(allocation.pool.ledger, self) {
      return Err(ForeignAccount)
    }
    if allocation.bytes < 0L {
      return Err(InvalidAmount)
    }
    for account in allocation.pool.accounts {
      match charges.get(account.id) {
        Some(charge) => {
          if !physical_equal(charge.account, account) {
            return Err(ForeignAccount)
          }
          charge.bytes = match checked_add(charge.bytes, allocation.bytes) {
            Ok(n) => n
            Err(e) => return Err(e)
          }
        }
        None => charges.set(account.id, { account, bytes: allocation.bytes })
      }
    }
  }
  let result : Array[Charge] = []
  for _, charge in charges {
    result.push(charge)
  }
  Ok(result)
}

///|
fn validate_charges(
  charges : Array[Charge],
  old : Array[Charge],
) -> Result[Unit, BudgetError] {
  if old.length() <= 8 {
    for charge in charges {
      let mut previous = 0L
      for prior in old {
        if physical_equal(prior.account, charge.account) {
          previous = prior.bytes
          break
        }
      }
      let account = charge.account
      let used = account.committed + account.reserved - previous
      if used < 0L || used > account.limit {
        return Err(InvalidTicketState)
      }
      if charge.bytes > account.limit - used {
        return Err(
          Exhausted(
            account.scope,
            account.label,
            used,
            charge.bytes,
            account.limit,
          ),
        )
      }
    }
    return Ok(())
  }
  let previous_by_id : Map[Int64, Int64] = Map([])
  for prior in old {
    previous_by_id.set(prior.account.id, prior.bytes)
  }
  for charge in charges {
    let previous = previous_by_id.get(charge.account.id).unwrap_or(0L)
    let account = charge.account
    let used = account.committed + account.reserved - previous
    if used < 0L || used > account.limit {
      return Err(InvalidTicketState)
    }
    if charge.bytes > account.limit - used {
      return Err(
        Exhausted(
          account.scope,
          account.label,
          used,
          charge.bytes,
          account.limit,
        ),
      )
    }
  }
  Ok(())
}

///|
pub fn Ledger::reserve(
  self : Ledger,
  allocations : Array[Allocation],
) -> Result[Ticket, BudgetError] {
  if self.live_tickets >= self.max_tickets {
    return Err(self.record_rejection(TicketLimit))
  }
  let charges = match self.aggregate(allocations) {
    Ok(c) => c
    Err(e) => return Err(self.record_rejection(e))
  }
  match validate_charges(charges, []) {
    Err(e) => return Err(self.record_rejection(e))
    Ok(_) => ()
  }
  for charge in charges {
    charge.account.reserved += charge.bytes
  }
  self.live_tickets += 1
  Ok({ ledger: self, charges, state: Reserved, busy: false })
}

///|
pub fn Ticket::commit(self : Ticket) -> Result[Unit, BudgetError] {
  if self.state != Reserved || self.busy {
    return Err(InvalidTicketState)
  }
  for charge in self.charges {
    charge.account.reserved -= charge.bytes
    charge.account.committed += charge.bytes
  }
  self.state = Committed
  Ok(())
}

///|
/// Atomic ownership/category transfer. Failure preserves the old ticket unchanged.
pub fn Ticket::replace(
  self : Ticket,
  allocations : Array[Allocation],
) -> Result[Unit, BudgetError] {
  if self.state == Released || self.busy {
    return Err(InvalidTicketState)
  }
  let charges = match self.ledger.aggregate(allocations) {
    Ok(c) => c
    Err(e) => return Err(self.ledger.record_rejection(e))
  }
  match validate_charges(charges, self.charges) {
    Err(e) => return Err(self.ledger.record_rejection(e))
    Ok(_) => ()
  }
  for old in self.charges {
    if self.state == Reserved {
      old.account.reserved -= old.bytes
    } else {
      old.account.committed -= old.bytes
    }
  }
  for charge in charges {
    if self.state == Reserved {
      charge.account.reserved += charge.bytes
    } else {
      charge.account.committed += charge.bytes
    }
  }
  self.charges = charges
  Ok(())
}

///|
/// Rollback and committed release share a single terminal operation; double release is an error.
pub fn Ticket::release(self : Ticket) -> Result[Unit, BudgetError] {
  if self.state == Released || self.busy {
    return Err(InvalidTicketState)
  }
  for charge in self.charges {
    if self.state == Reserved {
      charge.account.reserved -= charge.bytes
    } else {
      charge.account.committed -= charge.bytes
    }
  }
  self.state = Released
  self.charges = []
  self.ledger.live_tickets -= 1
  Ok(())
}

///|
pub fn Ledger::committed(self : Ledger) -> Int64 {
  self.total.committed
}

///|
pub fn Ledger::reserved(self : Ledger) -> Int64 {
  self.total.reserved
}

///|
pub fn Ledger::occupied(self : Ledger) -> Int64 {
  self.total.committed + self.total.reserved
}

///|
pub fn Ledger::live_tickets(self : Ledger) -> Int {
  self.live_tickets
}

///|
pub fn Account::occupied(self : Account) -> Int64 {
  self.committed + self.reserved
}

///|
pub fn Pool::occupied(self : Pool) -> Int64 {
  self.accounts[2].occupied()
}

///|
pub fn Pool::limit(self : Pool) -> Int64 {
  self.accounts[2].limit
}

///|
pub fn Ledger::ordinary_available(self : Ledger) -> Int64 {
  self.ordinary.limit - self.ordinary.occupied()
}

///|
pub fn Pool::reserve(self : Pool, bytes : Int64) -> Result[Ticket, BudgetError] {
  self.ledger.reserve([self.allocation(bytes)])
}

///|
/// Share a category constraint across ordinary and protected control pools.
pub fn Pool::category_account(self : Pool) -> Account {
  self.accounts[2]
}

///|
pub fn ResourceKind::name(self : ResourceKind) -> String {
  match self {
    Receive => "receive"
    RuntimeEvent => "runtime"
    Inflight => "inflight"
    Pending => "pending"
    InboundQoS2 => "inbound_qos2"
    Retained => "retained"
    Will => "will"
    Subscription => "subscription"
    SessionMetadata => "session_metadata"
    Outbound => "outbound"
    Routing => "routing"
    Snapshot => "snapshot"
    AuthRequest => "auth_request"
    AuthWorkspace => "auth_workspace"
    AuthResult => "auth_result"
    ConnectionMetadata => "connection_metadata"
    LimiterMetadata => "limiter_metadata"
    Infrastructure => "infrastructure"
    ControlEvent => "control_event"
    ControlRuntime => "control_runtime"
    ControlFrame => "control_frame"
    ControlWork => "control_work"
    ManagementInfrastructure => "management_infrastructure"
    ManagementRequest => "management_request"
    ManagementCache => "management_cache"
    ManagementIndex => "management_index"
    ManagementQuery => "management_query"
    ManagementCursor => "management_cursor"
    ManagementOperation => "management_operation"
    ManagementAudit => "management_audit"
  }
}

///|
pub fn Ledger::record_rejection(
  self : Ledger,
  error : BudgetError,
) -> BudgetError {
  let key = match error {
    Exhausted(_, label, _, _, _) => label
    TicketLimit => "ticket_count"
    _ => "invariant"
  }
  // Diagnostic cardinality is bounded even for a custom library caller's labels.
  let key = if self.rejections.length() >= 64 && !self.rejections.contains(key) {
    "other"
  } else {
    key
  }
  let count = self.rejections.get(key).unwrap_or(0L)
  self.rejections.set(
    key,
    if count < 9223372036854775807L {
      count + 1L
    } else {
      count
    },
  )
  error
}

///|
/// ControlFrame/ControlRuntime are subcaps of the canonical outbound/runtime
/// categories and are omitted to avoid counting their bytes twice.
pub fn Ledger::usage(
  self : Ledger,
) -> Array[(ResourceKind, Int64, Int64, Int64)] {
  let result : Array[(ResourceKind, Int64, Int64, Int64)] = []
  for kind, account in self.categories {
    if kind != ControlFrame && kind != ControlRuntime {
      result.push((kind, account.committed, account.reserved, account.limit))
    }
  }
  result
}

///|
pub fn Ledger::rejection_count(self : Ledger, key : String) -> Int64 {
  self.rejections.get(key).unwrap_or(0L)
}

///|
pub fn Ledger::rejections_total(self : Ledger) -> Int64 {
  let mut sum = 0L
  for _, count in self.rejections {
    sum = match checked_add(sum, count) {
      Ok(n) => n
      Err(_) => 9223372036854775807L
    }
  }
  sum
}
