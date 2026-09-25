///|
pub fn BrokerState::next_durable_promotion(
  self : BrokerState,
) -> @session.ClientId? {
  if self.inflight_total >= self.config.max_inflight_total() {
    return None
  }
  let ids = self.sessions.keys().collect()
  ids.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.value(), right.value())
  })
  if ids.is_empty() {
    return None
  }
  let start = self.promotion_cursor % ids.length()
  for offset in 0..<ids.length() {
    let index = (start + offset) % ids.length()
    let id = ids[index]
    let session = self.sessions.get(id).unwrap()
    if session.is_attached() &&
      session.pending_count() > 0 &&
      session.inflight_count() < self.config.max_inflight_per_session() {
      if !self.pending_head_authorized(session) {
        continue
      }
      let head = session.pending_head_cost().unwrap()
      let limits = self.config.resources
      if head <=
        limits.get("max_inflight_bytes_per_session") - session.inflight_bytes() &&
        head <= limits.get("max_inflight_bytes_total") - self.inflight_bytes() {
        self.promotion_cursor = (index + 1) % ids.length()
        return Some(id)
      }
    }
  }
  None
}
