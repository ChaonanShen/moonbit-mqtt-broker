///|
test "C-T10 MQTT5 finite session is logically absent before GC" {
  let state = BrokerState::new(BrokerConfig::new(8, 16, 8).unwrap())
  let id = @session.ClientId::new("expiry-v5").unwrap()
  let fresh = state
    .prepare_activation(
      id,
      @session.Persistent,
      @security.Anonymous,
      v5_resume=false,
      v5_retention=@session.FiniteV5(2U),
      now_mono_ms=100L,
    )
    .unwrap()
  ignore(state.commit_activation(fresh).unwrap())
  ignore(
    state
    .apply(
      DetachSessionV5({ client_id: id, now_mono_ms: 1000L, now_wall_ms: 10000L }),
    )
    .unwrap(),
  )
  let before = state
    .prepare_activation(
      id,
      @session.Persistent,
      @security.Anonymous,
      v5_resume=true,
      v5_retention=@session.FiniteV5(2U),
      now_mono_ms=2999L,
    )
    .unwrap()
  assert_true(before.session_present())
  state.cancel_activation(before).unwrap()
  let expired = state
    .prepare_activation(
      id,
      @session.Persistent,
      @security.Anonymous,
      v5_resume=true,
      v5_retention=@session.FiniteV5(2U),
      now_mono_ms=3000L,
    )
    .unwrap()
  assert_false(expired.session_present())
  state.cancel_activation(expired).unwrap()
  let actions = state
    .apply(ExpireSessionsV5({ now_wall_ms: 12000L, now_mono_ms: 3000L }))
    .unwrap()
  assert_true(actions.any(action => action is SessionExpired(_)))
  assert_false(state.has_session(id))
}
