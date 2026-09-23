///|
fn audit_event(actor : String) -> AuditEvent {
  {
    sequence: 0L,
    timestamp_ms: 100L,
    actor_token_id: actor,
    operation_id: "boot.1",
    kind: DeleteSession,
    target: "1",
    phase: "accepted",
    result: "accepted",
    effect_applied: false,
    state_revision: None,
  }
}

///|
test "audit ring overwrites oldest and exposes sequence gap" {
  let ring = AuditRing::new(2)
  assert_true(ring.append(audit_event("a")))
  assert_true(ring.append(audit_event("b")))
  assert_true(ring.append(audit_event("a")))
  assert_eq(ring.count(), 2)
  assert_eq(ring.overwritten_total(), 1L)
  assert_eq(ring.oldest_available_sequence(), 2L)
  let page = ring.page("a", 0L, 10, 2)
  assert_eq(page.items.length(), 1)
  assert_eq(page.items[0].sequence, 3L)
  assert_false(page.gap)
  let gap = ring.page("a", 1L, 10, 2)
  assert_false(gap.gap)
  ignore(ring.append(audit_event("b")))
  assert_true(ring.page("a", 1L, 10, 2).gap)
}

///|
test "audit sparse actor read advances with bounded empty page" {
  let ring = AuditRing::new(4)
  for _ in 0..<4 {
    assert_true(ring.append(audit_event("other")))
  }
  let first = ring.page("self", 0L, 1, 2)
  assert_eq(first.items.length(), 0)
  assert_eq(first.scanned, 2)
  assert_eq(first.next_after_sequence, Some(2L))
  let second = ring.page("self", 2L, 1, 2)
  assert_eq(second.items.length(), 0)
  assert_eq(second.next_after_sequence, None)
  assert_eq(ring.count(), 4)
}
