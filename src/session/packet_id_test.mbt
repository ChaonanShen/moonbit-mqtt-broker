///|
test "packet id allocator wraps without reusing inflight ids" {
  let allocator = PacketIdAllocator::new(next=65535).unwrap()
  let occupied = SessionPacketId::new(1).unwrap()
  assert_eq(allocator.allocate(id => id == occupied).unwrap().value(), 65535)
  assert_eq(allocator.allocate(id => id == occupied).unwrap().value(), 2)
  assert_eq(allocator.next(), 3)
}

///|
test "packet id allocator rejects boundaries and reports exhaustion" {
  assert_eq(SessionPacketId::new(0), Err(SessionError::InvalidPacketId(0)))
  assert_eq(
    SessionPacketId::new(65536),
    Err(SessionError::InvalidPacketId(65536)),
  )
  let allocator = PacketIdAllocator::new().unwrap()
  assert_eq(allocator.allocate(_ => true), Err(SessionError::PacketIdExhausted))
}

///|
test "packet id allocator is deterministic across ten thousand releases" {
  let allocator = PacketIdAllocator::new().unwrap()
  for expected in 1..<=10000 {
    assert_eq(allocator.allocate(_ => false).unwrap().value(), expected)
  }
}
