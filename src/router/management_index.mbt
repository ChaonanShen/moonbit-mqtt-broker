///|
pub(all) struct AdminSessionIdentity {
  handle : Int64
  lifecycle_version : Int64
  client_id : @session.ClientId
} derive(Eq, Debug)

///|
/// An optional derived index. It is not serialized in snapshots. Any failure
/// disables management detail/commands without changing MQTT business state.
pub struct AdminSessionIndex {
  slots : @slot_index.SlotIndex
  by_client : Map[@session.ClientId, AdminSessionIdentity]
  by_handle : Map[Int64, @session.ClientId]
  mut next_handle : Int64
  mut available : Bool
  generation : Int64
}

///|
fn AdminSessionIndex::new(capacity : Int) -> AdminSessionIndex {
  {
    slots: @slot_index.SlotIndex::new(capacity),
    by_client: Map([]),
    by_handle: Map([]),
    next_handle: 1L,
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
  let index = AdminSessionIndex::new(self.config.max_sessions())
  for client_id, _ in self.sessions {
    index.register(client_id)
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
