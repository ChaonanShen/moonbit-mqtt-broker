///|
test "C-T16 receive maximum one preserves QoS2 credit until terminal PUBCOMP" {
  let ledger = WireRxLedger::new(1)
  let first = match ledger.reserve(7, 2) {
    RxNew(value) => value
    _ => abort("expected first reservation")
  }
  assert_eq(ledger.count(), 1)
  assert_eq(ledger.reserve(7, 2), RxDuplicateQoS2(first))
  assert_eq(ledger.reserve(8, 1), RxQuotaExceeded)
  assert_eq(ledger.count(), 1)
  assert_true(!ledger.complete({ ..first, generation: first.generation + 1L }))
  assert_eq(ledger.count(), 1)
  assert_true(ledger.complete(first))
  assert_true(!ledger.complete(first))
  assert_true(ledger.reserve(8, 1) is RxNew(_))
}

///|
test "C-T16 colliding QoS1 packet id cannot release original credit" {
  let ledger = WireRxLedger::new(1)
  let first = match ledger.reserve(42, 1) {
    RxNew(value) => value
    _ => abort("expected first reservation")
  }
  assert_eq(ledger.reserve(42, 1), RxPacketIdInUse)
  assert_eq(ledger.reserve(42, 2), RxPacketIdInUse)
  assert_eq(ledger.count(), 1)
  assert_true(ledger.complete(first))
  let second = match ledger.reserve(42, 1) {
    RxNew(value) => value
    _ => abort("expected replacement reservation")
  }
  assert_true(!ledger.complete(first))
  assert_true(ledger.complete(second))
  assert_eq(ledger.count(), 0)
}
