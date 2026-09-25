///|
test "C-T08 MQTT5 clean start and session expiry are independent" {
  assert_eq(resume_from_clean_start(true), StartFresh)
  assert_eq(resume_from_clean_start(false), ResumeExisting)
  assert_eq(retention_from_connect(0U), DropOnClose)
  assert_eq(retention_from_connect(30U), FiniteV5(30U))
  assert_eq(retention_from_connect(0xffffffffU), InfiniteV5)
  assert_eq(
    retention_from_disconnect(DropOnClose, 1U),
    Err(InvalidExpiryOverride),
  )
  assert_eq(retention_from_disconnect(FiniteV5(30U), 0U), Ok(DropOnClose))
}

///|
test "C-T29 clock restore cannot refill expired TTL after rollback" {
  let deadline = Deadline::from_seconds(1000L, 10000L, 10U).unwrap()
  assert_eq(deadline.wall_due_ms, 20000L)
  assert_eq(deadline.remaining_at(6000L), 5000L)
  let restored = Deadline::restore(500L, 9000L, 15000L, 8000L, 20000L).unwrap()
  assert_eq(restored.saved_remaining_ms, 5000L)
  let again = Deadline::restore(
    100L,
    8000L,
    17000L,
    restored.saved_remaining_ms,
    restored.wall_due_ms,
  ).unwrap()
  assert_eq(again.saved_remaining_ms, 3000L)
  assert_eq(
    Deadline::restore(100L, 30000L, 17000L, 5000L, 20000L).unwrap().saved_remaining_ms,
    0L,
  )
  assert_eq(Deadline::new(9223372036854775807L, 1L, 1L), Err(ClockOverflow))
}

///|
test "C-T08 client session keeps retention separate from resume mode" {
  let id = ClientId::new("v5-retention").unwrap()
  let short = ClientSession::new_with_retention(id, FiniteV5(30U))
  assert_eq(short.mode(), Persistent)
  assert_eq(short.retention(), FiniteV5(30U))
  let clean = ClientSession::new_with_retention(id, DropOnClose)
  assert_eq(clean.mode(), Clean)
  assert_eq(clean.retention(), DropOnClose)
  assert_eq(
    ClientSession::new(id, mode=Persistent).retention(),
    LegacyBrokerPolicy,
  )
}
