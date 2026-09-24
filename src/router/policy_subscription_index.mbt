///|
pub(all) struct PolicySubscriptionRow {
  id : Int64
  client_id : @session.ClientId
  filter : @topic.TopicFilter
} derive(Eq, Debug)

///|
pub(all) struct PolicySubscriptionPage {
  rows : Array[PolicySubscriptionRow]
  positions : Array[Int]
  next_slot : Int
  scanned : Int
  has_more : Bool
} derive(Eq, Debug)

///|
priv struct PolicySubscriptionSlots {
  slots : @slot_index.SlotIndex
  by_client : Map[@session.ClientId, Map[@topic.TopicFilter, Int64]]
  by_id : Map[Int64, PolicySubscriptionRow]
  mut next_id : Int64
}

///|
fn PolicySubscriptionSlots::new(capacity : Int) -> PolicySubscriptionSlots {
  {
    slots: @slot_index.SlotIndex::new(capacity),
    by_client: Map([]),
    by_id: Map([]),
    next_id: 1L,
  }
}

///|
fn PolicySubscriptionSlots::track(
  self : PolicySubscriptionSlots,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
) -> Bool {
  if self.next_id == 9223372036854775807L {
    return false
  }
  let id = self.next_id
  match self.slots.put(id.to_string()) {
    @slot_index.Added(_) => ()
    _ => return false
  }
  self.next_id += 1L
  let filters = match self.by_client.get(client_id) {
    Some(value) => value
    None => {
      let value : Map[@topic.TopicFilter, Int64] = Map([])
      self.by_client.set(client_id, value)
      value
    }
  }
  filters.set(filter, id)
  self.by_id.set(id, { id, client_id, filter })
  true
}

///|
fn PolicySubscriptionSlots::untrack(
  self : PolicySubscriptionSlots,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
) -> Bool {
  let filters = match self.by_client.get(client_id) {
    Some(value) => value
    None => return false
  }
  let id = match filters.get(filter) {
    Some(value) => value
    None => return false
  }
  if !self.slots.remove(id.to_string()) {
    return false
  }
  filters.remove(filter)
  if filters.is_empty() {
    self.by_client.remove(client_id)
  }
  self.by_id.remove(id)
  true
}

///|
fn PolicySubscriptionSlots::page(
  self : PolicySubscriptionSlots,
  start : Int,
  scan_limit : Int,
) -> PolicySubscriptionPage {
  let physical = self.slots.page(start, scan_limit, scan_limit, _ => true)
  let rows : Array[PolicySubscriptionRow] = []
  for key in physical.keys {
    let id = @string.parse_int64(key) catch {
      _ => abort("invalid core policy subscription id")
    }
    rows.push(self.by_id.get(id).unwrap())
  }
  {
    rows,
    positions: physical.positions,
    next_slot: physical.next_slot,
    scanned: physical.scanned,
    has_more: physical.has_more,
  }
}

///|
fn PolicySubscriptionSlots::check_invariants(
  self : PolicySubscriptionSlots,
  count : Int,
) -> Bool {
  if self.slots.live_count() != count ||
    self.by_id.length() != count ||
    !self.slots.check_invariants() {
    return false
  }
  for id, row in self.by_id {
    if self.slots.get(id.to_string()) is None ||
      self.by_client.get(row.client_id) is None ||
      self.by_client.get(row.client_id).unwrap().get(row.filter) != Some(id) {
      return false
    }
  }
  true
}

///|
/// Called at startup before MQTT listeners bind; no management index required.
pub fn SubscriptionIndex::enable_policy_slots(
  self : SubscriptionIndex,
  capacity : Int,
) -> Bool {
  if self.policy_slots is Some(_) {
    return true
  }
  if capacity < self.count {
    return false
  }
  let slots = PolicySubscriptionSlots::new(capacity)
  for client_id, filters in self.by_client {
    for filter, _ in filters {
      if !slots.track(client_id, filter) {
        return false
      }
    }
  }
  self.policy_slots = Some(slots)
  true
}

///|
pub fn SubscriptionIndex::policy_page(
  self : SubscriptionIndex,
  start : Int,
  scan_limit : Int,
) -> PolicySubscriptionPage? {
  self.policy_slots.map(slots => slots.page(start, scan_limit))
}

///|
pub fn SubscriptionIndex::policy_identity(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
) -> Int64? {
  match self.policy_slots {
    Some(slots) =>
      match slots.by_client.get(client_id) {
        Some(filters) => filters.get(filter)
        None => None
      }
    None => None
  }
}
