///|
fn operation_fixture(
  table : OperationTable,
  actor? : String = "operator",
  key? : String = "Key_0123456789abc",
  request? : String = "DELETE:/v1/sessions/1:\"boot:s:1:1\"",
) -> OperationRecord {
  table
  .insert(actor, DeleteSession, "1", request, key, "snapshot", 100L, 1000L)
  .unwrap()
}

///|
test "operation idempotency reuses exact request and isolates actors" {
  let table = OperationTable::new("boot", 16, 900000L)
  let first = operation_fixture(table)
  assert_eq(
    table.lookup_key(
      "operator", "Key_0123456789abc", "DELETE:/v1/sessions/1:\"boot:s:1:1\"",
    ),
    KeyMatch(first),
  )
  assert_eq(
    table.lookup_key("operator", "Key_0123456789abc", "other"),
    KeyConflict,
  )
  assert_eq(table.lookup_key("second", "Key_0123456789abc", "other"), KeyUnused)
  let second = operation_fixture(table, actor="second", request="other")
  assert_true(second.id != first.id)
  assert_true(table.get(first.id, "second") is None)
  assert_eq(table.get(first.id, "operator"), Some(first))
  assert_true(table.check_invariants())
}

///|
test "accepted running terminal and TTL preserve applied effect" {
  let table = OperationTable::new("boot", 16, 1000L)
  let accepted = operation_fixture(table)
  assert_true(table.start(accepted.id, Applying, 101L))
  assert_eq(table.get_internal(accepted.id).unwrap().state, Running)
  assert_eq(table.cleanup(100000L, 16), 0)
  assert_true(
    table.finish(
      accepted.id,
      false,
      true,
      false,
      true,
      Some("shutdown"),
      Some(7L),
      Some(6L),
      105L,
      100000L,
    ),
  )
  let terminal = table.get_internal(accepted.id).unwrap()
  assert_eq(terminal.state, Failed)
  assert_true(terminal.effect_applied)
  assert_true(terminal.timed_out)
  assert_eq(terminal.completion_scope, "runtime")
  assert_eq(table.cleanup(100999L, 16), 0)
  assert_eq(table.cleanup(101000L, 16), 1)
  assert_true(table.get_internal(accepted.id) is None)
  assert_eq(
    table.lookup_key(
      "operator", "Key_0123456789abc", "DELETE:/v1/sessions/1:\"boot:s:1:1\"",
    ),
    KeyUnused,
  )
  assert_true(table.check_invariants())
}

///|
test "capacity failure is atomic and terminal reap frees a slot" {
  let table = OperationTable::new("boot", 1, 1000L)
  let first = operation_fixture(table)
  assert_true(
    table.insert(
      "operator",
      DeleteSession,
      "2",
      "request2",
      "Key_0123456789abd",
      "off",
      101L,
      1000L,
    )
    is Err(OperationCapacity),
  )
  assert_eq(table.live_count(), 1)
  assert_true(table.get_internal(first.id) is Some(_))
  assert_true(
    table.finish(
      first.id,
      true,
      true,
      false,
      false,
      None,
      Some(9L),
      None,
      102L,
      2000L,
    ),
  )
  assert_eq(table.cleanup(3000L, 1), 1)
  let second = table
    .insert(
      "operator",
      DeleteSession,
      "2",
      "request2",
      "Key_0123456789abd",
      "off",
      103L,
      4000L,
    )
    .unwrap()
  assert_true(second.id != first.id)
  assert_true(table.check_invariants())
}
