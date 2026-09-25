///|
pub fn BrokerState::next_durable_expiration(
  self : BrokerState,
  now_ms : Int64,
) -> (@session.ClientId, DurableLifecycleKind)? {
  let now_mono_ms = @budget.monotonic_ms()
  if self.session_expiry.peek_due(now_mono_ms) is Some(entry) {
    let client_id = @session.ClientId::new(entry.key).unwrap()
    if self.sessions.get(client_id) is Some(session) &&
      self.session_incarnation(client_id) == Some(entry.revision) &&
      session.logically_expired(now_mono_ms) {
      return Some((client_id, Delete))
    }
  }
  let expiry_ms = match self.config.persistent_session_expiry_ms() {
    Some(value) if now_ms > 0L => value
    _ => return None
  }
  if self.last_expiration_check_ms is Some(previous) && now_ms < previous {
    self.time_regression_reported = true
    return None
  }
  self.last_expiration_check_ms = Some(now_ms)
  self.time_regression_reported = false
  let mut initialize : @session.ClientId? = None
  let mut due : (@session.ClientId, Int64)? = None
  for client_id, session in self.sessions {
    if session.retention() != @session.LegacyBrokerPolicy ||
      session.is_attached() {
      continue
    }
    let detached_at_ms = session.detached_at_ms().unwrap_or(0L)
    if detached_at_ms == 0L {
      if initialize is None ||
        compare_utf8_for_sort(client_id.value(), initialize.unwrap().value()) <
        0 {
        initialize = Some(client_id)
      }
    } else if now_ms >= detached_at_ms && now_ms - detached_at_ms >= expiry_ms {
      match due {
        None => due = Some((client_id, detached_at_ms))
        Some((old_id, old_time)) =>
          if detached_at_ms < old_time ||
            (
              detached_at_ms == old_time &&
              compare_utf8_for_sort(client_id.value(), old_id.value()) < 0
            ) {
            due = Some((client_id, detached_at_ms))
          }
      }
    }
  }
  match initialize {
    Some(client_id) => Some((client_id, SetDetachedAt(now_ms)))
    None => due.map(item => (item.0, Delete))
  }
}
