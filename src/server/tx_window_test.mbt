///|
test "C-T18 terminal ACK returns one credit and stale lease returns none" {
  let window = TxWindow::new(1)
  let first = match window.reserve(10L) {
    TxReserved(lease) => lease
    _ => abort("expected first lease")
  }
  assert_eq(window.available(), 0)
  assert_eq(window.reserve(10L), TxAlreadyReserved(first))
  assert_eq(window.reserve(11L), TxWindowFull)
  assert_true(!window.terminal({ ..first, generation: first.generation + 1L }))
  assert_eq(window.available(), 0)
  assert_true(window.terminal(first))
  assert_true(!window.terminal(first))
  assert_eq(window.available(), 1)
  let second = match window.reserve(10L) {
    TxReserved(lease) => lease
    _ => abort("expected second lease")
  }
  assert_true(second != first)
  assert_true(!window.terminal(first))
  assert_true(window.terminal(second))
  assert_eq(window.available(), 1)
}
