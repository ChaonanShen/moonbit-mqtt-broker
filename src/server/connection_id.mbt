///|
pub struct ConnectionId(Int64) derive(Eq, Hash, Debug)

///|
pub fn ConnectionId::new(value : Int64) -> ConnectionId {
  ConnectionId(value)
}

///|
pub fn ConnectionId::value(self : ConnectionId) -> Int64 {
  let ConnectionId(value) = self
  value
}

///|
pub struct ConnectionIdAllocator {
  mut next : Int64
}

///|
pub fn ConnectionIdAllocator::new() -> ConnectionIdAllocator {
  { next: 1L }
}

///|
pub fn ConnectionIdAllocator::with_next(next : Int64) -> ConnectionIdAllocator {
  { next, }
}

///|
pub fn ConnectionIdAllocator::allocate(
  self : ConnectionIdAllocator,
) -> Result[ConnectionId, ServerError] {
  if self.next <= 0L || self.next == 9223372036854775807L {
    return Err(ConnectionIdExhausted)
  }
  let id = ConnectionId(self.next)
  self.next = self.next + 1L
  Ok(id)
}
