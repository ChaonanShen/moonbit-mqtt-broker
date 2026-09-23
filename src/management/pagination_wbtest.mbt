///|
fn cursor_fixture() -> CursorRecord {
  {
    actor_token_id: "operator",
    route: "sessions",
    filters: "attached=false",
    session_handle: "",
    next_slot: 7,
    audit_after_sequence: None,
    index_generation: 1L,
    expires_monotonic_ms: 0L,
  }
}

///|
test "cursor binds actor route filter and generation without extending ttl" {
  let table = CursorTable::new(2, 60000L, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  let key = table
    .install("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", cursor_fixture(), 100L)
    .unwrap()
  assert_eq(
    table
    .lookup(key, "operator", "sessions", "attached=false", "", 1L, 101L)
    .unwrap().next_slot,
    7,
  )
  assert_true(
    table.lookup(key, "other", "sessions", "attached=false", "", 1L, 101L)
    is Err(CursorForbidden),
  )
  assert_true(
    table.lookup(key, "operator", "retained", "attached=false", "", 1L, 101L)
    is Err(CursorMismatch),
  )
  assert_true(
    table.lookup(key, "operator", "sessions", "attached=false", "", 2L, 101L)
    is Err(ExpiredCursor),
  )
  assert_true(
    table.lookup(key, "operator", "sessions", "attached=false", "", 1L, 60100L)
    is Err(ExpiredCursor),
  )
}

///|
test "cursor collision never replaces existing owner and ring expires" {
  let table = CursorTable::new(1, 10L, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  let key = table
    .install("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", cursor_fixture(), 100L)
    .unwrap()
  assert_true(
    table.install(
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      { ..cursor_fixture(), actor_token_id: "other" },
      101L,
    )
    is Err(CursorEntropy),
  )
  assert_eq(table.live_count(), 1)
  assert_eq(table.cleanup(109L, 1), 0)
  assert_eq(table.cleanup(110L, 1), 1)
  assert_eq(table.live_count(), 0)
  assert_true(
    table.lookup(key, "operator", "sessions", "attached=false", "", 1L, 110L)
    is Err(ExpiredCursor),
  )
}

///|
test "cursor rejects altered and previous boot handles" {
  let table = CursorTable::new(2, 100L, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  assert_true(
    table.lookup("bad", "operator", "sessions", "", "", 1L, 0L)
    is Err(InvalidCursor),
  )
  assert_true(
    table.lookup(
      "cccccccccccccccccccccccccccccccc.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "operator",
      "sessions", "", "", 1L, 0L,
    )
    is Err(ExpiredCursor),
  )
}
