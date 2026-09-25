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

///|
test "C-T08 MQTT5 resume decision is independent of new expiry" {
  let state = bytes_state([])
  let id = bytes_client(state, "resume-v5")
  let resumed = state
    .prepare_activation(
      id,
      @session.Clean,
      @security.Anonymous,
      v5_resume=true,
      v5_retention=@session.DropOnClose,
      now_mono_ms=100L,
    )
    .unwrap()
  assert_true(resumed.session_present())
  ignore(state.commit_activation(resumed).unwrap())
  assert_eq(state.session_retention(id), Some(@session.DropOnClose))
  let fresh = state
    .prepare_activation(
      id,
      @session.Persistent,
      @security.Anonymous,
      v5_resume=false,
      v5_retention=@session.FiniteV5(30U),
      now_mono_ms=200L,
    )
    .unwrap()
  assert_false(fresh.session_present())
  ignore(state.commit_activation(fresh).unwrap())
  assert_eq(state.session_retention(id), Some(@session.FiniteV5(30U)))
  assert_eq(state.check_invariants(), Ok(()))
}
