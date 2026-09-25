///|
test "reload admission bounds and coalesces SIGHUP storms" {
  let disabled = ReloadRequests::new(false)
  assert_eq(disabled.signal(0L), ReloadDisabled)
  assert_eq(disabled.management(0L, 0L), ReloadDisabled)
  let queue = ReloadRequests::new(true)
  assert_eq(queue.signal(0L), ReloadStarted(1L))
  assert_eq(queue.signal(0L), ReloadQueued(2L))
  assert_eq(queue.signal(0L), ReloadCoalesced)
  assert_eq(queue.management(0L, 0L), ReloadBusy)
  assert_true(queue.can_activate(1L, 0L))
  assert_eq(
    queue.finish_active(1L, 1L),
    Some({ id: 2L, source: LocalSignal, base_epoch: 1L, expected_epoch: None }),
  )
  assert_true(queue.can_activate(2L, 1L))
  assert_false(queue.can_activate(2L, 2L))
  assert_eq(queue.finish_active(2L, 2L), None)
}

///|
test "reload management request preconditions survive its wait" {
  let queue = ReloadRequests::new(true)
  assert_eq(queue.management(2L, 3L), ReloadStale)
  assert_eq(queue.management(3L, 3L), ReloadStarted(1L))
  assert_eq(queue.management(3L, 3L), ReloadQueued(2L))
  assert_eq(queue.management(3L, 3L), ReloadBusy)
  assert_eq(queue.signal(3L), ReloadBusy)
  assert_true(queue.can_activate(1L, 3L))
  assert_eq(
    queue.finish_active(1L, 4L),
    Some({
      id: 2L,
      source: Management,
      base_epoch: 3L,
      expected_epoch: Some(3L),
    }),
  )
  assert_false(queue.can_activate(2L, 4L))
  assert_eq(queue.finish_active(2L, 4L), None)
}
