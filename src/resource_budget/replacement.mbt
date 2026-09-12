///|
priv struct ReplacementEntry {
  ticket : Ticket
  charges : Array[Charge]
}

///|
pub struct Replacement {
  priv entries : Array[ReplacementEntry]
  priv extra : Array[Charge]
  priv mut finished : Bool
}

///|
/// Reserve all positive deltas before preparing replacement objects. Existing
/// committed charges remain owned until commit; tickets are locked meanwhile.
pub fn Ledger::prepare_replacement(
  self : Ledger,
  requests : Array[(Ticket, Array[Allocation])],
) -> Result[Replacement, BudgetError] {
  if requests.length() > 65536 {
    return Err(InvalidConfiguration)
  }
  let entries : Array[ReplacementEntry] = []
  let old_sums : Map[Int64, Int64] = Map([])
  let new_sums : Map[Int64, Charge] = Map([])
  for request in requests {
    let (ticket, allocations) = request
    if !physical_equal(ticket.ledger, self) {
      return Err(ForeignAccount)
    }
    if ticket.state != Committed ||
      ticket.busy ||
      entries.any(e => physical_equal(e.ticket, ticket)) {
      return Err(InvalidTicketState)
    }
    let charges = match self.aggregate(allocations) {
      Ok(c) => c
      Err(e) => return Err(e)
    }
    for charge in ticket.charges {
      let next = match
        checked_add(old_sums.get(charge.account.id).unwrap_or(0L), charge.bytes) {
        Ok(n) => n
        Err(e) => return Err(e)
      }
      old_sums.set(charge.account.id, next)
    }
    for charge in charges {
      match new_sums.get(charge.account.id) {
        None =>
          new_sums.set(charge.account.id, {
            account: charge.account,
            bytes: charge.bytes,
          })
        Some(prior) =>
          prior.bytes = match checked_add(prior.bytes, charge.bytes) {
            Ok(n) => n
            Err(e) => return Err(e)
          }
      }
    }
    entries.push({ ticket, charges })
  }
  let extra : Array[Charge] = []
  for id, charge in new_sums {
    let previous = old_sums.get(id).unwrap_or(0L)
    if charge.bytes > previous {
      let increment = charge.bytes - previous
      let used = charge.account.occupied()
      if increment > charge.account.limit - used {
        return Err(
          Exhausted(charge.account.scope, used, increment, charge.account.limit),
        )
      }
      extra.push({ account: charge.account, bytes: increment })
    }
  }
  for charge in extra {
    charge.account.reserved += charge.bytes
  }
  for entry in entries {
    entry.ticket.busy = true
  }
  Ok({ entries, extra, finished: false })
}

///|
pub fn Replacement::commit(self : Replacement) -> Result[Unit, BudgetError] {
  if self.finished {
    return Err(InvalidTicketState)
  }
  // Remove every old charge before adding any new charge: category swaps at
  // full capacity must not transiently overdraw an account.
  for entry in self.entries {
    for charge in entry.ticket.charges {
      charge.account.committed -= charge.bytes
    }
  }
  for charge in self.extra {
    charge.account.reserved -= charge.bytes
  }
  for entry in self.entries {
    for charge in entry.charges {
      charge.account.committed += charge.bytes
    }
    entry.ticket.charges = entry.charges
    entry.ticket.busy = false
  }
  self.finished = true
  Ok(())
}

///|
pub fn Replacement::rollback(self : Replacement) -> Result[Unit, BudgetError] {
  if self.finished {
    return Err(InvalidTicketState)
  }
  for charge in self.extra {
    charge.account.reserved -= charge.bytes
  }
  for entry in self.entries {
    entry.ticket.busy = false
  }
  self.finished = true
  Ok(())
}
