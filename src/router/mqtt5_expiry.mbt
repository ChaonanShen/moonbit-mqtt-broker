///|
fn BrokerState::expire_sessions_v5(
  self : BrokerState,
  now_wall_ms : Int64,
  now_mono_ms : Int64,
  max_work : Int,
) -> Result[Array[BrokerAction], RouterError] {
  if max_work < 1 {
    return Err(InvariantViolation("invalid MQTT5 expiry work limit"))
  }
  let actions = match self.expire_sessions(now_wall_ms, max_items=max_work) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut completed = 0
  for action in actions {
    if action is SessionExpired(_) {
      completed += 1
    }
  }
  let remaining = max_work - completed
  if remaining <= 0 {
    return Ok(actions)
  }
  let candidates : Array[(@session.ClientId, Int64)] = []
  for client_id, session in self.sessions {
    if session.retention() is @session.FiniteV5(_) &&
      !session.is_attached() &&
      session.logically_expired(now_mono_ms) {
      let due = session
        .expiry_deadline()
        .map(value => value.mono_due_ms)
        .unwrap_or(0L)
      candidates.push((client_id, due))
    }
  }
  candidates.sort_by(fn(left, right) {
    if left.1 < right.1 {
      -1
    } else if left.1 > right.1 {
      1
    } else {
      compare_utf8_for_sort(left.0.value(), right.0.value())
    }
  })
  for index in 0..<@cmp.minimum(remaining, candidates.length()) {
    let client_id = candidates[index].0
    match self.remove_session(client_id) {
      Ok(removed) => {
        actions.append(removed)
        actions.push(SessionExpired(client_id))
      }
      Err(error) => return Err(error)
    }
  }
  Ok(actions)
}
