///|
pub(all) enum CursorError {
  InvalidCursor
  ExpiredCursor
  CursorForbidden
  CursorMismatch
  CursorCapacity
  CursorEntropy
} derive(Eq, Debug)

///|
pub(all) struct CursorRecord {
  actor_token_id : String
  route : String
  filters : String
  session_handle : String
  next_slot : Int
  audit_after_sequence : Int64?
  index_generation : Int64
  expires_monotonic_ms : Int64
} derive(Eq, Debug)

///|
/// The random cursor is only an opaque table key. All authority is rechecked
/// against the current token and this server-side binding on every page.
pub struct CursorTable {
  boot_id : String
  ttl_ms : Int64
  slots : Array[String?]
  records : Map[String, CursorRecord]
  mut next_slot : Int
  mut cleanup_slot : Int
}

///|
pub fn CursorTable::new(
  capacity : Int,
  ttl_ms : Int64,
  boot_id : String,
) -> CursorTable {
  {
    boot_id,
    ttl_ms,
    slots: Array::make(capacity, None),
    records: Map([]),
    next_slot: 0,
    cleanup_slot: 0,
  }
}

///|
pub fn CursorTable::live_count(self : CursorTable) -> Int {
  self.records.length()
}

///|
fn cursor_nonce_hex(raw : FixedArray[Byte]) -> String? {
  if raw.length() != 16 {
    return None
  }
  let alphabet = "0123456789abcdef"
  let output : Array[Byte] = []
  for byte in raw {
    let number = byte.to_int()
    output.push(alphabet[number / 16].to_int().to_byte())
    output.push(alphabet[number % 16].to_int().to_byte())
  }
  Some(@utf8.decode(Bytes::from_array(output))) catch {
    _ => None
  }
}

///|
fn valid_cursor_text(value : String) -> Bool {
  let parts = value.split(".").to_array()
  if parts.length() != 2 || parts[0].length() != 32 || parts[1].length() != 32 {
    return false
  }
  for part in parts {
    for byte in part {
      let number = byte.to_int()
      if !((number >= 48 && number <= 57) || (number >= 97 && number <= 102)) {
        return false
      }
    }
  }
  true
}

///|
fn CursorTable::install(
  self : CursorTable,
  nonce : String,
  record : CursorRecord,
  now_monotonic_ms : Int64,
) -> Result[String, CursorError] {
  if nonce.length() != 32 {
    return Err(InvalidCursor)
  }
  let key = self.boot_id + "." + nonce
  if self.records.contains(key) {
    return Err(CursorEntropy)
  }
  let capacity = self.slots.length()
  if capacity == 0 || self.records.length() == capacity {
    return Err(CursorCapacity)
  }
  for inspected in 0..<capacity {
    let slot = (self.next_slot + inspected) % capacity
    match self.slots[slot] {
      None => {
        self.slots[slot] = Some(key)
        self.records.set(key, {
          ..record,
          expires_monotonic_ms: now_monotonic_ms + self.ttl_ms,
        })
        self.next_slot = (slot + 1) % capacity
        return Ok(key)
      }
      Some(existing) =>
        match self.records.get(existing) {
          Some(old) =>
            if now_monotonic_ms >= old.expires_monotonic_ms {
              self.records.remove(existing)
              self.slots[slot] = Some(key)
              self.records.set(key, {
                ..record,
                expires_monotonic_ms: now_monotonic_ms + self.ttl_ms,
              })
              self.next_slot = (slot + 1) % capacity
              return Ok(key)
            }
          None => return Err(CursorCapacity)
        }
    }
  }
  Err(CursorCapacity)
}

///|
pub fn CursorTable::issue(
  self : CursorTable,
  record : CursorRecord,
  now_monotonic_ms : Int64,
) -> Result[String, CursorError] {
  if now_monotonic_ms < 0L ||
    self.ttl_ms <= 0L ||
    record.next_slot < 0 ||
    record.actor_token_id.length() > 32 ||
    record.filters.length() > 128 {
    return Err(InvalidCursor)
  }
  if self.records.length() >= self.slots.length() {
    // A bounded cleanup pass may recover expired slots without a whole-table
    // sweep on the request path.
    ignore(self.cleanup(now_monotonic_ms, 16))
    if self.records.length() >= self.slots.length() {
      return Err(CursorCapacity)
    }
  }
  for _ in 0..<3 {
    let raw = match @management_native.secure_random(16) {
      Ok(value) => value
      Err(_) => return Err(CursorEntropy)
    }
    let nonce = match cursor_nonce_hex(raw) {
      Some(value) => value
      None => return Err(CursorEntropy)
    }
    match self.install(nonce, record, now_monotonic_ms) {
      Err(CursorEntropy) => continue
      result => return result
    }
  }
  Err(CursorEntropy)
}

///|
pub fn CursorTable::lookup(
  self : CursorTable,
  key : String,
  actor_token_id : String,
  route : String,
  filters : String,
  session_handle : String,
  index_generation : Int64,
  now_monotonic_ms : Int64,
) -> Result[CursorRecord, CursorError] {
  if !valid_cursor_text(key) {
    return Err(InvalidCursor)
  }
  if !key.has_prefix(self.boot_id + ".") {
    return Err(ExpiredCursor)
  }
  let record = match self.records.get(key) {
    Some(value) => value
    None => return Err(ExpiredCursor)
  }
  if now_monotonic_ms >= record.expires_monotonic_ms {
    return Err(ExpiredCursor)
  }
  if record.actor_token_id != actor_token_id {
    return Err(CursorForbidden)
  }
  if record.route != route ||
    record.filters != filters ||
    record.session_handle != session_handle {
    return Err(CursorMismatch)
  }
  if record.index_generation != index_generation {
    return Err(ExpiredCursor)
  }
  Ok(record)
}

///|
/// Inspect no more than limit table slots per maintenance tick.
pub fn CursorTable::cleanup(
  self : CursorTable,
  now_monotonic_ms : Int64,
  limit : Int,
) -> Int {
  let capacity = self.slots.length()
  if capacity == 0 || limit <= 0 {
    return 0
  }
  let mut removed = 0
  let mut inspected = 0
  while inspected < limit && inspected < capacity {
    let slot = self.cleanup_slot
    self.cleanup_slot = (slot + 1) % capacity
    if self.slots[slot] is Some(key) {
      match self.records.get(key) {
        Some(record) =>
          if now_monotonic_ms >= record.expires_monotonic_ms {
            self.records.remove(key)
            self.slots[slot] = None
            removed += 1
          }
        None => self.slots[slot] = None
      }
    }
    inspected += 1
  }
  removed
}
