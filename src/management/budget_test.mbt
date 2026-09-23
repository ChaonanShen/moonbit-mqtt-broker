///|
test "disabled management owns no ledger categories or tickets" {
  let ledger = @budget.Ledger::new(10000000L, 100000L).unwrap()
  assert_true(
    ManagementBudget::maybe_new(ManagementConfig::default(), ledger) is Ok(None),
  )
  assert_eq(ledger.usage().length(), 0)
  assert_eq(ledger.live_tickets(), 0)
}

///|
test "exact ordinary capacity reserves all three management categories" {
  let config = ManagementConfig::new(enabled=true, token_file="/tmp/tokens").unwrap()
  let total = config.required_bytes()
  let ledger = @budget.Ledger::new(total + 100L, 100L).unwrap()
  let owner = ManagementBudget::new(config, ledger).unwrap()
  assert_eq(ledger.committed(), total)
  assert_eq(ledger.reserved(), 0L)
  assert_eq(ledger.live_tickets(), 1)
  let rows = ledger.usage()
  assert_eq(rows.length(), 3)
  let mut used = 0L
  for row in rows {
    let (_, committed, _, _) = row
    used += committed
  }
  assert_eq(used, total)
  let control_pool = ledger.pool(@budget.ControlEvent, 100L).unwrap()
  let control = control_pool.reserve(100L).unwrap()
  control.commit().unwrap()
  assert_eq(ledger.committed(), total + 100L)
  control.release().unwrap()
  assert_true(owner.close())
  assert_eq(ledger.occupied(), 0L)
  assert_eq(ledger.live_tickets(), 0)
  assert_true(owner.close())
}

///|
test "parent reserve failure never leaves partial charges" {
  let config = ManagementConfig::new(enabled=true, token_file="/tmp/tokens").unwrap()
  let ledger = @budget.Ledger::new(config.required_bytes() - 1L, 0L).unwrap()
  assert_true(ManagementBudget::new(config, ledger) is Err(_))
  assert_eq(ledger.occupied(), 0L)
  assert_eq(ledger.live_tickets(), 0)
}

///|
test "slow request lease keeps parent until final release" {
  let config = ManagementConfig::new(enabled=true, token_file="/tmp/tokens").unwrap()
  let ledger = @budget.Ledger::new(config.required_bytes() + 100L, 0L).unwrap()
  let owner = ManagementBudget::new(config, ledger).unwrap()
  let held : Array[ManagementRequestLease] = []
  for _ in 0..<config.max_connections() {
    held.push(owner.acquire().unwrap())
  }
  assert_eq(owner.active_count(), config.max_connections())
  assert_true(owner.acquire() is None)
  assert_false(owner.close())
  assert_eq(ledger.committed(), config.required_bytes())
  assert_true(owner.acquire() is None)
  for index in 0..<(held.length() - 1) {
    assert_true(held[index].release())
    assert_false(held[index].release())
    assert_false(owner.is_closed())
  }
  assert_true(held[held.length() - 1].release())
  assert_true(owner.is_closed())
  assert_eq(ledger.occupied(), 0L)
  assert_eq(ledger.live_tickets(), 0)
}

///|
test "ten thousand request-slot cycles conserve the parent reservation" {
  let config = ManagementConfig::new(enabled=true, token_file="/tmp/tokens").unwrap()
  let ledger = @budget.Ledger::new(config.required_bytes() + 100L, 0L).unwrap()
  let owner = ManagementBudget::new(config, ledger).unwrap()
  let baseline = ledger.committed()
  for _ in 0..<10000 {
    let slot = owner.acquire().unwrap()
    assert_true(slot.release())
  }
  assert_eq(owner.active_count(), 0)
  assert_eq(ledger.committed(), baseline)
  assert_eq(ledger.live_tickets(), 1)
  assert_true(owner.close())
  assert_eq(ledger.live_tickets(), 0)
}
