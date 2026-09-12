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
} derive(Eq, Hash, Debug)

///|
pub struct Account {
  authority : Array[Int]
  id : Int64
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
      scope: Global,
      limit: total,
      committed: 0L,
      reserved: 0L,
    },
    ordinary: {
      authority,
      id: 1L,
      scope: Global,
      limit: total - control,
      committed: 0L,
      reserved: 0L,
    },
    control: {
      authority,
      id: 2L,
      scope: Control,
      limit: control,
      committed: 0L,
      reserved: 0L,
    },
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
      let account = match self.account(Category, limit) {
        Ok(a) => a
        Err(e) => return Err(e)
      }
      self.categories.set(kind, account)
      account
    }
  }
  let partition = if kind == ControlEvent {
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
      return Err(Exhausted(account.scope, used, charge.bytes, account.limit))
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
    return Err(TicketLimit)
  }
  let charges = match self.aggregate(allocations) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  match validate_charges(charges, []) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  for charge in charges {
    charge.account.reserved += charge.bytes
  }
  self.live_tickets += 1
  Ok({ ledger: self, charges, state: Reserved })
}

///|
pub fn Ticket::commit(self : Ticket) -> Result[Unit, BudgetError] {
  if self.state != Reserved {
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
  if self.state == Released {
    return Err(InvalidTicketState)
  }
  let charges = match self.ledger.aggregate(allocations) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  match validate_charges(charges, self.charges) {
    Err(e) => return Err(e)
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
  if self.state == Released {
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
