///|
test "session activation cancellation restores existing owner and all budget reservations" {
  let state = bytes_state([])
  let id = bytes_client(state, "old")
  ignore(bytes_subscribe(state, id, "t"))
  ignore(bytes_publish(state, id, "t", b"body").unwrap())
  let before = state.export_snapshot()
  let used = state.managed_bytes()
  let pending = state
    .prepare_activation(id, @session.Clean, @security.Anonymous)
    .unwrap()
  state.cancel_activation(pending).unwrap()
  assert_eq(state.export_snapshot(), before)
  assert_eq(state.managed_bytes(), used)
  assert_eq(state.check_invariants(), Ok(()))
  assert_true(state.commit_activation(pending) is Err(_))
}

///|
test "new session activation can roll back without a leaked identity ticket" {
  let state = bytes_state([])
  let pending = state
    .prepare_activation(
      @session.ClientId::new("new").unwrap(),
      @session.Persistent,
      @security.Anonymous,
    )
    .unwrap()
  assert_true(state.managed_bytes() > 0L)
  assert_eq(state.session_count(), 0)
  state.cancel_activation(pending).unwrap()
  assert_eq(state.managed_bytes(), 0L)
  assert_eq(state.check_invariants(), Ok(()))
}
