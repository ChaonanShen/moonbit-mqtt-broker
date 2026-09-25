///|
fn BrokerState::expiry_index_bytes(self : BrokerState) -> Int64 {
  let mut used = self.session_expiry.used_bytes() +
    self.retained.expiry_index_bytes() +
    self.will_expiry.used_bytes()
  for _, session in self.sessions {
    used += session.pending_expiry_bytes()
  }
  used
}

///|
fn BrokerState::expiry_index_fits(
  self : BrokerState,
  additional : Int64,
) -> Bool {
  let used = self.expiry_index_bytes()
  additional <= 8388608L - used && used + additional >= 0L
}
