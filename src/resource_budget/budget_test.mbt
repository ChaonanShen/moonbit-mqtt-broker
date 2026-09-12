///|
test "checked costs reject overflow before arithmetic and count UTF8" {
  let max = 9223372036854775807L
  assert_eq(checked_add(max, 0L), Ok(max))
  assert_eq(checked_add(max, 1L), Err(Overflow))
  assert_eq(checked_mul(max, 2L), Err(Overflow))
  assert_eq(checked_mul(max, 0L), Ok(0L))
  assert_eq(checked_mul(-1L, 0L), Err(InvalidAmount))
  assert_eq(checked_sub(0L, 1L), Err(InvalidAmount))
  assert_eq(utf8_bytes("a中😀"), 8L)
  assert_eq(message_cost("a中😀", 0L), Ok(104L))
  assert_eq(message_cost("a", max), Err(Overflow))
  assert_eq(subscription_cost("中/#"), 69L)
  assert_eq(identity_cost("id", "user:a"), 264L)
  assert_eq(qos2_metadata_cost(), 64L)
}

///|
test "exact limit and reserved committed release phases" {
  let ledger = Ledger::new(100L, 10L).unwrap()
  let pool = ledger.pool(Inflight, 90L).unwrap()
  let ticket = ledger.reserve([pool.allocation(90L)]).unwrap()
  assert_eq(ledger.reserved(), 90L)
  assert_eq(ledger.committed(), 0L)
  assert_true(ledger.reserve([pool.allocation(1L)]) is Err(_))
  ticket.commit().unwrap()
  assert_eq(ledger.reserved(), 0L)
  assert_eq(ledger.committed(), 90L)
  assert_eq(ticket.commit(), Err(InvalidTicketState))
  ticket.release().unwrap()
  assert_eq(ledger.occupied(), 0L)
  assert_eq(ticket.release(), Err(InvalidTicketState))
  assert_eq(ticket.replace([]), Err(InvalidTicketState))
  assert_eq(ledger.live_tickets(), 0)
}

///|
test "control partition remains available at ordinary saturation" {
  let ledger = Ledger::new(100L, 10L).unwrap()
  let ordinary = ledger.pool(Pending, 100L).unwrap()
  let control = ledger.pool(ControlEvent, 100L).unwrap()
  let a = ledger.reserve([ordinary.allocation(90L)]).unwrap()
  assert_true(ledger.reserve([ordinary.allocation(1L)]) is Err(_))
  let b = ledger.reserve([control.allocation(10L)]).unwrap()
  assert_eq(ledger.occupied(), 100L)
  assert_true(ledger.reserve([control.allocation(1L)]) is Err(_))
  a.release().unwrap()
  assert_true(ledger.reserve([control.allocation(1L)]) is Err(_))
  b.release().unwrap()
}

///|
test "third dimension failure rolls back shared global and category reservations" {
  let ledger = Ledger::new(100L, 0L).unwrap()
  let session_cap = ledger.account(Session, 20L).unwrap()
  let p = ledger.pool(Pending, 100L).unwrap().with_account(session_cap).unwrap()
  let f = ledger
    .pool(Inflight, 100L)
    .unwrap()
    .with_account(session_cap)
    .unwrap()
  assert_true(ledger.reserve([p.allocation(11L), f.allocation(10L)]) is Err(_))
  assert_eq(ledger.occupied(), 0L)
  assert_eq(session_cap.occupied(), 0L)
  assert_eq(p.occupied(), 0L)
  let ticket = ledger.reserve([p.allocation(10L), f.allocation(10L)]).unwrap()
  assert_eq(session_cap.occupied(), 20L)
  ticket.release().unwrap()
}

///|
test "atomic transfer at full global checks destination and preserves failed ticket" {
  let ledger = Ledger::new(100L, 0L).unwrap()
  let p = ledger.pool(Pending, 100L).unwrap()
  let f = ledger.pool(Inflight, 50L).unwrap()
  let ticket = ledger.reserve([p.allocation(100L)]).unwrap()
  ticket.commit().unwrap()
  assert_true(ticket.replace([f.allocation(100L)]) is Err(_))
  assert_eq(p.occupied(), 100L)
  assert_eq(f.occupied(), 0L)
  ticket.replace([p.allocation(50L), f.allocation(50L)]).unwrap()
  assert_eq(ledger.committed(), 100L)
  assert_eq(ledger.reserved(), 0L)
  ticket.replace([f.allocation(50L)]).unwrap()
  assert_eq(ledger.occupied(), 50L)
  ticket.release().unwrap()
}

///|
test "duplicate allocations sum and category creation cannot reset capacity" {
  let ledger = Ledger::new(100L, 0L).unwrap()
  let pool = ledger.pool(Retained, 50L).unwrap()
  assert_true(
    ledger.reserve([pool.allocation(30L), pool.allocation(30L)]) is Err(_),
  )
  let t = ledger.reserve([pool.allocation(50L)]).unwrap()
  let same = ledger.pool(Retained, 50L).unwrap()
  assert_eq(same.occupied(), 50L)
  assert_true(ledger.pool(Retained, 100L) is Err(InvalidConfiguration))
  t.release().unwrap()
}

///|
test "foreign ledgers and foreign owner accounts rejected even when numeric ids collide" {
  let a = Ledger::new(100L, 0L).unwrap()
  let b = Ledger::new(100L, 0L).unwrap()
  let pool = a.pool(Receive, 100L).unwrap()
  assert_true(b.reserve([pool.allocation(1L)]) is Err(ForeignAccount))
  assert_true(
    pool.with_account(b.account(Connection, 10L).unwrap())
    is Err(ForeignAccount),
  )
  assert_eq(a.occupied(), 0L)
  assert_eq(b.occupied(), 0L)
}

///|
test "zero byte tickets are bounded and rollback returns ticket slots" {
  let ledger = Ledger::new(0L, 0L, max_tickets=1).unwrap()
  let first = ledger.reserve([]).unwrap()
  assert_true(ledger.reserve([]) is Err(TicketLimit))
  first.release().unwrap()
  ledger.reserve([]).unwrap().release().unwrap()
  assert_eq(ledger.live_tickets(), 0)
}

///|
test "ten thousand fixed seed operations agree with an independent scalar model" {
  let ledger = Ledger::new(101L, 0L).unwrap()
  let pool = ledger.pool(RuntimeEvent, 101L).unwrap()
  let slots : Array[Ticket?] = Array::make(16, None)
  let amounts : Array[Int64] = Array::make(16, 0L)
  let mut model = 0L
  let mut seed = 17
  for _ in 0..<10000 {
    seed = (seed * 73 + 19) % 1009
    let index = seed % 16
    let amount = (seed % 23).to_int64()
    match slots[index] {
      None => {
        let result = ledger.reserve([pool.allocation(amount)])
        if model + amount <= 101L {
          let t = result.unwrap()
          t.commit().unwrap()
          slots[index] = Some(t)
          amounts[index] = amount
          model += amount
        } else {
          assert_true(result is Err(_))
        }
      }
      Some(t) =>
        if seed % 3 == 0 {
          t.release().unwrap()
          slots[index] = None
          model -= amounts[index]
          amounts[index] = 0L
        } else {
          let result = t.replace([pool.allocation(amount)])
          if model - amounts[index] + amount <= 101L {
            result.unwrap()
            model = model - amounts[index] + amount
            amounts[index] = amount
          } else {
            assert_true(result is Err(_))
          }
        }
    }
    assert_eq(ledger.committed(), model)
    assert_eq(ledger.reserved(), 0L)
  }
  for slot in slots {
    if slot is Some(t) {
      t.release().unwrap()
    }
  }
  assert_eq(ledger.occupied(), 0L)
  assert_eq(ledger.live_tickets(), 0)
}

///|
test "rate multikey failure has no partial debit and duplicate keys cannot bypass cost" {
  let a = Bucket::new(0L, 10L, 0L).unwrap()
  let b = Bucket::new(0L, 2L, 0L).unwrap()
  assert_true(admit([(a, 5L), (b, 3L)], 0L) is Err(_))
  assert_eq(a.available_at(0L), 10L)
  assert_true(admit([(a, 6L), (a, 6L)], 0L) is Err(_))
  admit([(a, 4L), (a, 6L), (b, 2L)], 0L).unwrap()
  assert_eq(a.available_at(10000L), 0L)
  assert_eq(b.available_at(10000L), 0L)
}

///|
test "rate fractional refill regressions and maximum elapsed avoid overflow" {
  let bucket = Bucket::new(1L, 1L, 0L).unwrap()
  admit([(bucket, 1L)], 0L).unwrap()
  for time in [250L, 500L, 750L] {
    admit([(bucket, 0L)], time).unwrap()
  }
  assert_eq(bucket.available_at(999L), 0L)
  assert_eq(bucket.available_at(1000L), 1L)
  admit([(bucket, 1L)], 1000L).unwrap()
  assert_eq(bucket.available_at(500L), 0L)
  assert_eq(bucket.available_at(1999L), 0L)
  assert_eq(bucket.available_at(9223372036854775807L), 1L)
  let huge = Bucket::new(9223372036854775807L, 9223372036854775807L, 0L).unwrap()
  admit([(huge, 9223372036854775807L)], 0L).unwrap()
  assert_eq(huge.available_at(1000L), 9223372036854775807L)
  assert_true(huge.available_at(999L) > 0L)
}

///|
test "rate zero and invalid configurations have explicit meaning" {
  let zero = Bucket::new(0L, 0L, 0L).unwrap()
  assert_true(admit([(zero, 1L)], 1000L) is Err(_))
  assert_true(Bucket::new(-1L, 1L, 0L) is Err(_))
  assert_true(Ledger::new(1L, 2L) is Err(_))
  assert_true(admit([(zero, -1L)], 0L) is Err(_))
}

///|
test "budget exhaustion reports the precise category and records a bounded rejection" {
  let ledger = Ledger::new(1000L, 0L).unwrap()
  let pool = ledger.pool(Outbound, 10L).unwrap()
  assert_true(
    pool.reserve(11L) is Err(Exhausted(Category, "outbound", 0L, 11L, 10L)),
  )
  assert_eq(ledger.rejection_count("outbound"), 1L)
  assert_eq(ledger.rejections_total(), 1L)
  assert_eq(ledger.occupied(), 0L)
}
