///|
test "prepared replacement keeps old ownership reserves growth and locks tickets" {
  let ledger = Ledger::new(100L, 0L).unwrap()
  let pool = ledger.pool(Inflight, 100L).unwrap()
  let ticket = ledger.reserve([pool.allocation(40L)]).unwrap()
  ticket.commit().unwrap()
  let tx = ledger
    .prepare_replacement([(ticket, [pool.allocation(90L)])])
    .unwrap()
  assert_eq(ledger.committed(), 40L)
  assert_eq(ledger.reserved(), 50L)
  assert_eq(ticket.release(), Err(InvalidTicketState))
  assert_eq(ticket.replace([]), Err(InvalidTicketState))
  tx.rollback().unwrap()
  assert_eq(ledger.occupied(), 40L)
  assert_eq(tx.commit(), Err(InvalidTicketState))
  ticket.release().unwrap()
}

///|
test "multiowner exchange swaps full categories without intermediate allocation" {
  let ledger = Ledger::new(100L, 0L).unwrap()
  let p = ledger.pool(Pending, 60L).unwrap()
  let f = ledger.pool(Inflight, 40L).unwrap()
  let a = ledger.reserve([p.allocation(60L)]).unwrap()
  let b = ledger.reserve([f.allocation(40L)]).unwrap()
  a.commit().unwrap()
  b.commit().unwrap()
  let tx = ledger
    .prepare_replacement([(a, [f.allocation(40L)]), (b, [p.allocation(60L)])])
    .unwrap()
  assert_eq(ledger.reserved(), 0L)
  tx.commit().unwrap()
  assert_eq(ledger.committed(), 100L)
  a.release().unwrap()
  assert_eq(f.occupied(), 0L)
  assert_eq(p.occupied(), 60L)
  b.release().unwrap()
}

///|
test "replacement failure and duplicate references leave all tickets usable" {
  let ledger = Ledger::new(100L, 0L).unwrap()
  let p = ledger.pool(Receive, 100L).unwrap()
  let a = ledger.reserve([p.allocation(50L)]).unwrap()
  let b = ledger.reserve([p.allocation(40L)]).unwrap()
  a.commit().unwrap()
  b.commit().unwrap()
  assert_true(
    ledger.prepare_replacement([
      (a, [p.allocation(70L)]),
      (b, [p.allocation(40L)]),
    ])
    is Err(_),
  )
  assert_eq(ledger.occupied(), 90L)
  assert_true(
    ledger.prepare_replacement([(a, []), (a, [])]) is Err(InvalidTicketState),
  )
  a.release().unwrap()
  b.release().unwrap()
  assert_eq(ledger.occupied(), 0L)
}

///|
test "limits are immutable and unknown negative or invalid partitions are rejected" {
  let defaults = Limits::default()
  let changed = defaults.with_value("max_retained_bytes_total", 10L).unwrap()
  assert_eq(defaults.get("max_retained_bytes_total"), 16777216L)
  assert_eq(changed.get("max_retained_bytes_total"), 10L)
  assert_true(defaults.with_value("unknown", 1L) is Err(_))
  assert_true(defaults.with_value("max_retained_bytes_total", -1L) is Err(_))
  assert_true(
    defaults.with_value("max_managed_bytes_total", 1L).unwrap().validate()
    is Err(_),
  )
}

///|
test "default registry includes every byte and rate key before validation" {
  let limits = Limits::default()
  assert_eq(limits.validate(), Ok(()))
  for spec in byte_limit_specs() {
    let (_, key, value) = spec
    assert_eq(limits.get(key), value)
  }
  for spec in rate_limit_specs() {
    let (_, key, value) = spec
    assert_eq(limits.get(key), value)
  }
  assert_true(limits.rates_enabled())
  assert_true(limits.per_ip_enabled())
}

///|
test "native budget clock is nonnegative and monotonic" {
  let before = monotonic_ms()
  let after = monotonic_ms()
  assert_true(before >= 0L && after >= before)
}
