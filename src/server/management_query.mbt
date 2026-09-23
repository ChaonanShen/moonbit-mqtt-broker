///|
pub(all) struct ManagementConnectionView {
  connection_id : Int64
  phase : String
  client_id : String?
  principal : String?
  closing : Bool
} derive(Eq, Debug)

///|
/// Enable only after startup has reserved B index capacity and before accept.
pub fn RouterDriver::enable_management_connection_index(
  self : RouterDriver,
  max_connections : Int,
) -> Bool {
  if self.management_connections is Some(_) {
    return false
  }
  let index = @slot_index.SlotIndex::new(max_connections)
  for id, _ in self.sinks {
    if index.put(id.value().to_string()) is @slot_index.Full {
      self.management_connections_available = false
    }
  }
  self.management_connections = Some(index)
  self.management_connections_available
}

///|
pub fn RouterDriver::management_connection_index_available(
  self : RouterDriver,
) -> Bool {
  self.management_connections is Some(_) &&
  self.management_connections_available
}

///|
pub fn RouterDriver::management_connection_page(
  self : RouterDriver,
  start : Int,
  scan_limit : Int,
  limit : Int,
  accept : (ManagementConnectionView) -> Bool,
) -> @slot_index.SlotPage? {
  if !self.management_connection_index_available() {
    return None
  }
  let index = self.management_connections.unwrap()
  Some(
    index.page(start, scan_limit, limit, fn(key) {
      let id = @string.parse_int64(key) catch { _ => return false }
      match self.management_connection_view(id) {
        Some(view) => accept(view)
        None => false
      }
    }),
  )
}

///|
/// The index holds only ConnectionId strings. Live phase and principal come
/// from runtime at the single-writer read point.
pub fn RouterDriver::management_connection_view(
  self : RouterDriver,
  id : Int64,
) -> ManagementConnectionView? {
  if !self.management_connection_index_available() {
    return None
  }
  let connection_id = ConnectionId::new(id)
  if self.management_connections.unwrap().get(id.to_string()) is None {
    return None
  }
  let meta = match self.runtime.connections.get(connection_id) {
    Some(value) => value
    None => return None
  }
  let (phase, client_id) = match meta.phase {
    AwaitConnect => ("await_connect", None)
    Authenticating(_) => ("authenticating", None)
    Active(client_id) => ("active", Some(client_id.value()))
  }
  Some({
    connection_id: id,
    phase,
    client_id,
    principal: meta.principal.map(value => value.storage_value()),
    closing: false,
  })
}
