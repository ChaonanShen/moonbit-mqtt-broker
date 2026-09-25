///|
priv struct ResourceUsage {
  inflight : Int64
  pending : Int64
  inbound : Int64
  metadata : Int64
  subscriptions : Int64
} derive(Eq)

///|
priv struct OwnerResources {
  pools : Array[@budget.Pool]
  ticket : @budget.Ticket
  mut usage : ResourceUsage
}

///|
priv struct RouterResources {
  limits : @budget.Limits
  ledger : @budget.Ledger
  owners : Map[@session.ClientId, OwnerResources]
  pools : Array[@budget.Pool]
  retained_pool : @budget.Pool
  retained_ticket : @budget.Ticket
  scratch : @budget.Pool
  mut retained_bytes : Int64
}

///|
fn RouterResources::new(
  limits : @budget.Limits,
  ledger? : @budget.Ledger,
) -> RouterResources {
  let ledger = ledger.unwrap_or_else(() => {
    @budget.Ledger::new(
      limits.get("max_managed_bytes_total"),
      limits.get("control_reserve_bytes"),
    ).unwrap()
  })
  let pools = [
    ledger.pool(Inflight, limits.get("max_inflight_bytes_total")).unwrap(),
    ledger.pool(Pending, limits.get("max_pending_bytes_total")).unwrap(),
    ledger.pool(InboundQoS2, limits.get("max_managed_bytes_total")).unwrap(),
    ledger
    .pool(SessionMetadata, limits.get("max_session_metadata_bytes_total"))
    .unwrap(),
    ledger
    .pool(Subscription, limits.get("max_subscription_bytes_total"))
    .unwrap(),
  ]
  let retained_pool = ledger
    .pool(Retained, limits.get("max_retained_bytes_total"))
    .unwrap()
  let retained_ticket = ledger.reserve([]).unwrap()
  retained_ticket.commit().unwrap()
  let scratch = ledger
    .pool(Routing, limits.get("max_routing_scratch_bytes"))
    .unwrap()
  {
    limits,
    ledger,
    owners: Map([]),
    pools,
    retained_pool,
    retained_ticket,
    scratch,
    retained_bytes: 0L,
  }
}

///|
fn OwnerResources::allocations(
  self : OwnerResources,
  usage : ResourceUsage,
) -> Array[@budget.Allocation] {
  [
    self.pools[0].allocation(usage.inflight),
    self.pools[1].allocation(usage.pending),
    self.pools[2].allocation(usage.inbound),
    self.pools[3].allocation(usage.metadata),
    self.pools[4].allocation(usage.subscriptions),
  ]
}

///|
fn RouterResources::prepare_owner(
  self : RouterResources,
  usage : ResourceUsage,
) -> Result[OwnerResources, RouterError] {
  let combined = self.ledger
    .account(
      Session,
      self.limits.get("max_session_state_bytes"),
      label="session_state",
    )
    .unwrap()
  let pools = self.pools.copy()
  for index in 0..<3 {
    pools[index] = pools[index].with_account(combined).unwrap()
  }
  for
    pair in [
      (0, "max_inflight_bytes_per_session"),
      (1, "max_pending_bytes_per_session"),
      (4, "max_subscription_bytes_per_session"),
    ] {
    let (index, key) = pair
    pools[index] = pools[index]
      .with_account(
        self.ledger.account(Session, self.limits.get(key), label=key).unwrap(),
      )
      .unwrap()
  }
  let ticket = match self.ledger.reserve([]) {
    Ok(value) => value
    Err(error) => return Err(ByteResourceLimit(error))
  }
  let owner = OwnerResources::{ pools, ticket, usage }
  match ticket.replace(owner.allocations(usage)) {
    Ok(_) => Ok(owner)
    Err(error) => {
      ticket.release().unwrap()
      Err(ByteResourceLimit(error))
    }
  }
}

///|
fn RouterResources::add_owner(
  self : RouterResources,
  id : @session.ClientId,
  usage : ResourceUsage,
) -> Result[Unit, RouterError] {
  let owner = match self.prepare_owner(usage) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  owner.ticket.commit().unwrap()
  self.owners.set(id, owner)
  Ok(())
}

///|
fn RouterResources::set_usages(
  self : RouterResources,
  updates : Map[@session.ClientId, ResourceUsage],
) -> Result[Unit, RouterError] {
  if updates.is_empty() {
    return Ok(())
  }
  if updates.length() == 1 {
    for id, usage in updates {
      let owner = self.owners.get(id).unwrap()
      match owner.ticket.replace(owner.allocations(usage)) {
        Err(e) => return Err(ByteResourceLimit(e))
        Ok(_) => owner.usage = usage
      }
    }
    return Ok(())
  }
  let requests : Array[(@budget.Ticket, Array[@budget.Allocation])] = []
  for id, usage in updates {
    let owner = self.owners.get(id).unwrap()
    requests.push((owner.ticket, owner.allocations(usage)))
  }
  let replacement = match self.ledger.prepare_replacement(requests) {
    Ok(r) => r
    Err(e) => return Err(ByteResourceLimit(e))
  }
  replacement.commit().unwrap()
  for id, usage in updates {
    self.owners.get(id).unwrap().usage = usage
  }
  Ok(())
}

///|
fn RouterResources::set_retained(
  self : RouterResources,
  bytes : Int64,
) -> Result[Unit, RouterError] {
  if bytes == self.retained_bytes {
    return Ok(())
  }
  match self.retained_ticket.replace([self.retained_pool.allocation(bytes)]) {
    Err(e) => Err(ByteResourceLimit(e))
    Ok(_) => {
      self.retained_bytes = bytes
      Ok(())
    }
  }
}

///|
fn BrokerState::resource_usage(
  self : BrokerState,
  id : @session.ClientId,
) -> ResourceUsage {
  let session = self.sessions.get(id).unwrap()
  {
    inflight: session.inflight_bytes(),
    pending: session.pending_bytes(),
    inbound: session.inbound_qos2_count().to_int64() * 64L,
    metadata: @budget.identity_cost(id.value(), session.owner().storage_value()),
    subscriptions: self.subscriptions.cost_for(id),
  }
}

///|
/// Settles provisional, synchronous preparation after success or rollback.
fn BrokerState::settle_resources(
  self : BrokerState,
) -> Result[Unit, RouterError] {
  let removed : Array[@session.ClientId] = []
  let updates : Map[@session.ClientId, ResourceUsage] = Map([])
  for id, owner in self.resources.owners {
    if !self.sessions.contains(id) {
      removed.push(id)
    } else {
      let usage = self.resource_usage(id)
      if owner.usage != usage {
        updates.set(id, usage)
      }
    }
  }
  for id in removed {
    self.resources.owners.get(id).unwrap().ticket.release().unwrap()
    self.resources.owners.remove(id)
  }
  match self.resources.set_usages(updates) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  self.resources.set_retained(self.retained.total_cost())
}

///|
fn BrokerState::reserve_scratch(
  self : BrokerState,
  bytes : Int64,
) -> Result[@budget.Ticket, RouterError] {
  match
    self.resources.ledger.reserve([self.resources.scratch.allocation(bytes)]) {
    Ok(ticket) => Ok(ticket)
    Err(e) => Err(ByteResourceLimit(e))
  }
}

///|
pub fn BrokerState::resource_ledger(self : BrokerState) -> @budget.Ledger {
  self.resources.ledger
}

///|
pub fn BrokerState::managed_bytes(self : BrokerState) -> Int64 {
  self.resources.ledger.occupied()
}

///|
pub fn BrokerState::retained_bytes(self : BrokerState) -> Int64 {
  self.resources.retained_bytes
}

///|
pub fn BrokerState::inflight_bytes(self : BrokerState) -> Int64 {
  self.resources.pools[0].occupied()
}

///|
pub fn BrokerState::pending_bytes(self : BrokerState) -> Int64 {
  self.resources.pools[1].occupied()
}

///|
/// Bounded fair scan. A persistent cursor advances even when one FIFO head is
/// blocked; no head is skipped within its own session and no busy retry occurs.
pub fn BrokerState::resume_pending(self : BrokerState) -> Array[BrokerAction] {
  if self.pending_qos1_total == 0 {
    return []
  }
  let scan_pool = self.resources.ledger
    .pool(ControlWork, self.config.resources.get("control_reserve_bytes"))
    .unwrap()
  let scan = match scan_pool.reserve(self.sessions.length().to_int64() * 32L) {
    Ok(t) => t
    Err(_) => return []
  }
  defer scan.release().unwrap()
  let ids : Array[@session.ClientId] = []
  for id, session in self.sessions {
    if session.is_attached() && session.pending_count() > 0 {
      ids.push(id)
    }
  }
  ids.sort_by((a, b) => compare_utf8_for_sort(a.value(), b.value()))
  let actions : Array[BrokerAction] = []
  let start = if ids.is_empty() {
    0
  } else {
    self.promotion_cursor % ids.length()
  }
  let count = if ids.length() < 32 { ids.length() } else { 32 }
  for step in 0..<count {
    let id = ids[(start + step) % ids.length()]
    let session = self.sessions.get(id).unwrap()
    let mut batch = 0
    while batch < 32 &&
          session.pending_count() > 0 &&
          session.inflight_count() < self.config.max_inflight_per_session() &&
          self.inflight_count() < self.config.max_inflight_total() {
      if !self.pending_head_authorized(session) {
        break
      }
      let cost = session.pending_head_cost().unwrap()
      let scratch = match
        self.reserve_scratch(
          cost * 6L + session.pending_count().to_int64() * 16L,
        ) {
        Err(_) => break
        Ok(t) => t
      }
      let old = self.resources.owners.get(id).unwrap().usage
      let next = {
        ..old,
        inflight: old.inflight + cost,
        pending: old.pending - cost,
      }
      if self.resources.set_usages(Map([(id, next)])) is Err(_) {
        scratch.release().unwrap()
        break
      }
      let result = session.promote(
        self.session_limits(max_inflight=session.inflight_count() + 1),
      )
      match result {
        Err(_) => {
          ignore(self.resources.set_usages(Map([(id, old)])))
          scratch.release().unwrap()
          break
        }
        Ok(deliveries) => {
          if deliveries.is_empty() {
            ignore(self.resources.set_usages(Map([(id, old)])))
            scratch.release().unwrap()
            break
          }
          self.inflight_total += 1
          self.pending_qos1_total -= 1
          if session.mode() == @session.SessionMode::Persistent {
            self.mark_snapshot_dirty()
          }
          for delivery in deliveries {
            let message = delivery.message.unwrap()
            actions.push(
              delivery_with_metadata(
                {
                  recipient: id,
                  topic: message.topic,
                  payload: copy_router_bytes(message.payload),
                  qos: message.qos,
                  retain: message.retain,
                  packet_id: Some(delivery.packet_id),
                  dup: false,
                },
                message.metadata,
                message.subscription_identifiers,
              ),
            )
          }
        }
      }
      self.retain_action_lease(scratch)
      batch += 1
    }
  }
  self.promotion_cursor = if ids.is_empty() {
    0
  } else {
    (start + count) % ids.length()
  }
  actions
}

///|
fn BrokerState::retain_action_lease(
  self : BrokerState,
  ticket : @budget.Ticket,
) -> Unit {
  if self.action_scope {
    self.action_leases.push(ticket)
  } else {
    ticket.release().unwrap()
  }
}

///|
pub fn BrokerState::begin_action_scope(self : BrokerState) -> Unit {
  guard !self.action_scope else { abort("nested router action scope") }
  self.action_scope = true
}

///|
pub fn BrokerState::end_action_scope(self : BrokerState) -> Unit {
  for ticket in self.action_leases {
    ticket.release().unwrap()
  }
  self.action_leases.clear()
  self.action_scope = false
}

///|
pub fn BrokerState::admit_action_input(
  self : BrokerState,
  bytes : Int64,
  control? : Bool = false,
) -> Result[Unit, RouterError] {
  let result = if control {
    self.resources.ledger
    .pool(ControlWork, self.config.resources.get("control_reserve_bytes"))
    .unwrap()
    .reserve(bytes)
    .map_err(e => ByteResourceLimit(e))
  } else {
    self.reserve_scratch(bytes)
  }
  match result {
    Err(e) => Err(e)
    Ok(t) => {
      self.retain_action_lease(t)
      Ok(())
    }
  }
}

///|
/// Conservative overlap of export copies, encoder buffers and an active write.
pub fn BrokerState::snapshot_work_cost(
  self : BrokerState,
) -> Result[Int64, @budget.BudgetError] {
  let mut total = self.retained.total_cost()
  for id, owner in self.resources.owners {
    if self.sessions.get(id) is Some(session) &&
      session.mode() == @session.SessionMode::Persistent {
      let usage = owner.usage
      let cost = usage.inflight +
        usage.pending +
        usage.inbound +
        usage.metadata +
        usage.subscriptions
      total = match @budget.checked_add(total, cost) {
        Ok(n) => n
        Err(e) => return Err(e)
      }
    }
  }
  match @budget.checked_mul(total, 8L) {
    Ok(n) => @budget.checked_add(n, 1024L)
    Err(e) => Err(e)
  }
}
