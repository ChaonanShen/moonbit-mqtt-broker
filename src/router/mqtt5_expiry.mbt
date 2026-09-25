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
  let actions = match self.expire_sessions(now_wall_ms, max_items=1) {
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
  if remaining <= 0 || completed > 0 {
    return Ok(actions)
  }
  let mut work_bytes = 0L
  for _ in 0..<remaining {
    let entry = match self.session_expiry.peek_due(now_mono_ms) {
      Some(value) => value
      None => break
    }
    let client_id = match @session.ClientId::new(entry.key) {
      Ok(value) => value
      Err(_) => return Err(InvariantViolation("invalid session expiry key"))
    }
    let session = match self.sessions.get(client_id) {
      Some(value) => value
      None => return Err(InvariantViolation("stale session expiry key"))
    }
    if self.session_incarnation(client_id) != Some(entry.revision) ||
      !session.logically_expired(now_mono_ms) {
      return Err(InvariantViolation("session expiry identity changed"))
    }
    let cost = session.state_bytes() +
      self.subscriptions.subscription_count_for(client_id).to_int64() * 192L +
      128L
    if work_bytes > 0L && cost > 262144L - work_bytes {
      break
    }
    match self.remove_session(client_id) {
      Ok(removed) => {
        actions.append(removed)
        actions.push(SessionExpired(client_id))
        work_bytes += cost
      }
      Err(error) => return Err(error)
    }
  }
  Ok(actions)
}
