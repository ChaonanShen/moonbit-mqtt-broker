///|
pub struct BrokerMetrics {
  started_at_ms : Int64
  mut messages_received : Int64
  mut messages_sent : Int64
  mut messages_dropped : Int64
  mut authentication_failures : Int64
  mut acl_denials : Int64
  mut tls_handshake_failures : Int64
}

///|
pub fn BrokerMetrics::new(started_at_ms : Int64) -> BrokerMetrics {
  {
    started_at_ms,
    messages_received: 0L,
    messages_sent: 0L,
    messages_dropped: 0L,
    authentication_failures: 0L,
    acl_denials: 0L,
    tls_handshake_failures: 0L,
  }
}

///|
pub fn BrokerMetrics::messages_received(self : BrokerMetrics) -> Int64 {
  self.messages_received
}

///|
pub fn BrokerMetrics::messages_sent(self : BrokerMetrics) -> Int64 {
  self.messages_sent
}

///|
pub fn BrokerMetrics::messages_dropped(self : BrokerMetrics) -> Int64 {
  self.messages_dropped
}

///|
pub fn BrokerMetrics::authentication_failures(self : BrokerMetrics) -> Int64 {
  self.authentication_failures
}

///|
pub fn BrokerMetrics::acl_denials(self : BrokerMetrics) -> Int64 {
  self.acl_denials
}

///|
pub fn BrokerMetrics::tls_handshake_failures(self : BrokerMetrics) -> Int64 {
  self.tls_handshake_failures
}

///|
pub fn BrokerMetrics::uptime_seconds(
  self : BrokerMetrics,
  now_ms : Int64,
) -> Int64 {
  if now_ms <= self.started_at_ms {
    0L
  } else {
    (now_ms - self.started_at_ms) / 1000L
  }
}

///|
fn BrokerMetrics::record_received(self : BrokerMetrics) -> Unit {
  self.messages_received = self.messages_received + 1L
}

///|
fn BrokerMetrics::record_sent(self : BrokerMetrics) -> Unit {
  self.messages_sent = self.messages_sent + 1L
}

///|
fn BrokerMetrics::record_dropped(self : BrokerMetrics) -> Unit {
  self.messages_dropped = self.messages_dropped + 1L
}

///|
fn BrokerMetrics::record_authentication_failure(self : BrokerMetrics) -> Unit {
  self.authentication_failures = self.authentication_failures + 1L
}

///|
fn BrokerMetrics::record_acl_denial(self : BrokerMetrics) -> Unit {
  self.acl_denials = self.acl_denials + 1L
}

///|
pub fn BrokerMetrics::record_tls_handshake_failure(
  self : BrokerMetrics,
) -> Unit {
  self.tls_handshake_failures = self.tls_handshake_failures + 1L
}
