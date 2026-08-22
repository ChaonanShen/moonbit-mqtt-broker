///|
pub struct SessionPacketId {
  value : Int
} derive(Eq, Hash, Debug)

///|
pub fn SessionPacketId::new(
  value : Int,
) -> Result[SessionPacketId, SessionError] {
  if value < 1 || value > 65535 {
    Err(InvalidPacketId(value))
  } else {
    Ok({ value, })
  }
}

///|
pub fn SessionPacketId::value(self : SessionPacketId) -> Int {
  self.value
}

///|
pub struct PacketIdAllocator {
  mut next : Int
} derive(Eq, Debug)

///|
pub fn PacketIdAllocator::new(
  next? : Int = 1,
) -> Result[PacketIdAllocator, SessionError] {
  if next < 1 || next > 65535 {
    Err(InvalidPacketId(next))
  } else {
    Ok({ next, })
  }
}

///|
pub fn PacketIdAllocator::next(self : PacketIdAllocator) -> Int {
  self.next
}

///|
pub fn PacketIdAllocator::allocate(
  self : PacketIdAllocator,
  in_use : (SessionPacketId) -> Bool,
) -> Result[SessionPacketId, SessionError] {
  for _ in 0..<65535 {
    let candidate = SessionPacketId::new(self.next).unwrap()
    self.next = if self.next == 65535 { 1 } else { self.next + 1 }
    if !in_use(candidate) {
      return Ok(candidate)
    }
  }
  Err(PacketIdExhausted)
}
