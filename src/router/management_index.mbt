///|
pub(all) struct AdminSessionIdentity {
  handle : Int64
  lifecycle_version : Int64
  client_id : @session.ClientId
} derive(Eq, Debug)

///|
pub(all) struct AdminSubscriptionIdentity {
  client_id : @session.ClientId
  filter : @topic.TopicFilter
} derive(Eq, Debug)

///|
/// An optional derived index. It is not serialized in snapshots. Any failure
/// disables management detail/commands without changing MQTT business state.
pub struct AdminSessionIndex {
  slots : @slot_index.SlotIndex
  by_client : Map[@session.ClientId, AdminSessionIdentity]
  by_handle : Map[Int64, @session.ClientId]
  subscription_slots : @slot_index.SlotIndex
  subscription_rows : Map[String, AdminSubscriptionIdentity]
  subscription_keys : Map[@session.ClientId, Map[@topic.TopicFilter, String]]
  retained_slots : @slot_index.SlotIndex
  mut next_handle : Int64
  mut next_subscription_id : Int64
  mut available : Bool
  generation : Int64
}

///|
fn AdminSessionIndex::new(
  session_capacity : Int,
  subscription_capacity : Int,
  retained_capacity : Int,
) -> AdminSessionIndex {
  {
    slots: @slot_index.SlotIndex::new(session_capacity),
    by_client: Map([]),
    by_handle: Map([]),
    subscription_slots: @slot_index.SlotIndex::new(subscription_capacity),
    subscription_rows: Map([]),
    subscription_keys: Map([]),
    retained_slots: @slot_index.SlotIndex::new(retained_capacity),
    next_handle: 1L,
    next_subscription_id: 1L,
    available: true,
    generation: 1L,
  }
}

///|
pub fn AdminSessionIndex::available(self : AdminSessionIndex) -> Bool {
  self.available
}

///|
pub fn AdminSessionIndex::generation(self : AdminSessionIndex) -> Int64 {
  self.generation
}

///|
pub fn AdminSessionIndex::live_count(self : AdminSessionIndex) -> Int {
  self.slots.live_count()
}

///|
fn AdminSessionIndex::register(
  self : AdminSessionIndex,
  client_id : @session.ClientId,
) -> Unit {
  if !self.available {
    return
  }
  if self.by_client.contains(client_id) ||
    self.next_handle <= 0L ||
    self.next_handle == 9223372036854775807L {
    self.available = false
    return
  }
  let handle = self.next_handle
  self.next_handle += 1L
  match self.slots.put(handle.to_string()) {
    @slot_index.Added(_) => {
      let identity = { handle, lifecycle_version: 1L, client_id }
      self.by_client.set(client_id, identity)
      self.by_handle.set(handle, client_id)
    }
    _ => self.available = false
  }
}

///|
fn AdminSessionIndex::remove(
  self : AdminSessionIndex,
  client_id : @session.ClientId,
) -> Unit {
  if !self.available {
    return
  }
  match self.by_client.get(client_id) {
    None => self.available = false
    Some(identity) => {
      if !self.slots.remove(identity.handle.to_string()) {
        self.available = false
        return
      }
      self.by_client.remove(client_id)
      self.by_handle.remove(identity.handle)
    }
  }
}

///|
fn AdminSessionIndex::replace(
  self : AdminSessionIndex,
  client_id : @session.ClientId,
) -> Unit {
  self.remove(client_id)
  self.register(client_id)
}

///|
fn AdminSessionIndex::bump(
  self : AdminSessionIndex,
  client_id : @session.ClientId,
) -> Unit {
  if !self.available {
    return
  }
  match self.by_client.get(client_id) {
    None => self.available = false
    Some(identity) => {
      if identity.lifecycle_version == 9223372036854775807L {
        self.available = false
        return
      }
      self.by_client.set(client_id, {
        ..identity,
        lifecycle_version: identity.lifecycle_version + 1L,
      })
    }
  }
}

///|
pub fn AdminSessionIndex::identity_for_client(
  self : AdminSessionIndex,
  client_id : @session.ClientId,
) -> AdminSessionIdentity? {
  if self.available {
    self.by_client.get(client_id)
  } else {
    None
  }
}

///|
pub fn AdminSessionIndex::identity_for_handle(
  self : AdminSessionIndex,
  handle : Int64,
) -> AdminSessionIdentity? {
  if !self.available {
    return None
  }
  match self.by_handle.get(handle) {
    Some(client_id) => self.by_client.get(client_id)
    None => None
  }
}

///|
pub fn AdminSessionIndex::page(
  self : AdminSessionIndex,
  start : Int,
  scan_limit : Int,
  limit : Int,
  accept : (AdminSessionIdentity) -> Bool,
) -> @slot_index.SlotPage {
  if !self.available {
    return self.slots.page(0, 0, 0, fn(_) { false })
  }
  self.slots.page(start, scan_limit, limit, fn(key) {
    let handle = @string.parse_int64(key) catch { _ => return false }
    match self.identity_for_handle(handle) {
      Some(identity) => accept(identity)
      None => false
    }
  })
}

///|
/// Called after snapshot restore and before MQTT accept. Restored Sessions
/// receive new process-local handles; no V3 serialization field is added.
pub fn BrokerState::enable_management_index(self : BrokerState) -> Bool {
  if self.admin_sessions is Some(_) {
    return false
  }
  let index = AdminSessionIndex::new(
    self.config.max_sessions(),
    self.config.max_subscriptions_total(),
    self.config.max_retained_messages(),
  )
  for client_id, _ in self.sessions {
    index.register(client_id)
    for record in self.subscriptions.records_for(client_id) {
      index.register_subscription(client_id, record.filter)
    }
  }
  for topic in self.retained.topic_keys() {
    index.register_retained(topic)
  }
  self.admin_sessions = Some(index)
  index.available()
}

///|
pub fn BrokerState::management_index_available(self : BrokerState) -> Bool {
  self.admin_sessions is Some(index) && index.available()
}

///|
pub fn BrokerState::management_index(self : BrokerState) -> AdminSessionIndex? {
  self.admin_sessions
}

///|
fn AdminSessionIndex::register_subscription(
  self : AdminSessionIndex,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
) -> Unit {
  if !self.available {
    return
  }
  let existing = self.subscription_keys.get(client_id)
  if existing is Some(filters) && filters.contains(filter) {
    return
  }
  if self.next_subscription_id <= 0L ||
    self.next_subscription_id == 9223372036854775807L {
    self.available = false
    return
  }
  let key = self.next_subscription_id.to_string()
  self.next_subscription_id += 1L
  match self.subscription_slots.put(key) {
    @slot_index.Added(_) => {
      let filters = match existing {
        Some(value) => value
        None => {
          let created : Map[@topic.TopicFilter, String] = Map([])
          self.subscription_keys.set(client_id, created)
          created
        }
      }
      filters.set(filter, key)
      self.subscription_rows.set(key, { client_id, filter })
    }
    _ => self.available = false
  }
}

///|
fn AdminSessionIndex::remove_subscription(
  self : AdminSessionIndex,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
) -> Unit {
  if !self.available {
    return
  }
  match self.subscription_keys.get(client_id) {
    None => self.available = false
    Some(filters) =>
      match filters.get(filter) {
        None => self.available = false
        Some(key) => {
          if !self.subscription_slots.remove(key) {
            self.available = false
            return
          }
          filters.remove(filter)
          if filters.length() == 0 {
            self.subscription_keys.remove(client_id)
          }
          self.subscription_rows.remove(key)
        }
      }
  }
}

///|
fn AdminSessionIndex::remove_all_subscriptions(
  self : AdminSessionIndex,
  client_id : @session.ClientId,
) -> Unit {
  if self.subscription_keys.get(client_id) is Some(filters) {
    let keys = filters.keys().collect()
    for filter in keys {
      self.remove_subscription(client_id, filter)
    }
  }
}

///|
pub fn AdminSessionIndex::subscription_page(
  self : AdminSessionIndex,
  client_id : @session.ClientId,
  start : Int,
  scan_limit : Int,
  limit : Int,
) -> @slot_index.SlotPage {
  self.subscription_slots.page(start, scan_limit, limit, fn(key) {
    self.subscription_rows.get(key) is Some(row) && row.client_id == client_id
  })
}

///|
pub fn AdminSessionIndex::subscription_row(
  self : AdminSessionIndex,
  key : String,
) -> AdminSubscriptionIdentity? {
  if self.available {
    self.subscription_rows.get(key)
  } else {
    None
  }
}

///|
fn AdminSessionIndex::register_retained(
  self : AdminSessionIndex,
  topic : @topic.TopicName,
) -> Unit {
  if !self.available {
    return
  }
  if self.retained_slots.put(topic.value()) is @slot_index.Full {
    self.available = false
  }
}

///|
fn AdminSessionIndex::remove_retained(
  self : AdminSessionIndex,
  topic : @topic.TopicName,
) -> Unit {
  if self.available && !self.retained_slots.remove(topic.value()) {
    self.available = false
  }
}

///|
pub fn AdminSessionIndex::retained_page(
  self : AdminSessionIndex,
  start : Int,
  scan_limit : Int,
  limit : Int,
) -> @slot_index.SlotPage {
  self.retained_slots.page(start, scan_limit, limit, fn(_) { true })
}

///|
pub fn AdminSessionIndex::subscription_live_count(
  self : AdminSessionIndex,
) -> Int {
  self.subscription_slots.live_count()
}

///|
pub fn AdminSessionIndex::retained_live_count(self : AdminSessionIndex) -> Int {
  self.retained_slots.live_count()
}

///|
pub fn AdminSessionIndex::check_invariants(self : AdminSessionIndex) -> Bool {
  if !self.slots.check_invariants() ||
    !self.subscription_slots.check_invariants() ||
    !self.retained_slots.check_invariants() ||
    self.by_client.length() != self.slots.live_count() ||
    self.by_handle.length() != self.slots.live_count() ||
    self.subscription_rows.length() != self.subscription_slots.live_count() {
    return false
  }
  let mut pairs = 0
  for _, filters in self.subscription_keys {
    pairs += filters.length()
  }
  pairs == self.subscription_rows.length()
}
