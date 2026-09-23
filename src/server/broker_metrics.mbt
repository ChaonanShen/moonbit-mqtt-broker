///|
pub struct BrokerMetrics {
  mut snapshot_budget_deferred : Int64
  mut snapshot_dirty_age_ms : Int64
  mut qos2_received : Int64
  mut qos2_duplicates : Int64
  mut qos2_rejected : Int64
  started_at_ms : Int64
  mut messages_received : Int64
  mut messages_sent : Int64
  mut messages_dropped : Int64
  mut authentication_failures : Int64
  mut auth_requests : Int64
  mut auth_successes : Int64
  mut auth_bad_credentials : Int64
  mut auth_resource_rejections : Int64
  mut auth_deadline_rejections : Int64
  mut auth_late_results : Int64
  mut acl_denials : Int64
  mut tls_handshake_failures : Int64
}

///|
pub fn BrokerMetrics::new(started_at_ms : Int64) -> BrokerMetrics {
  {
    snapshot_budget_deferred: 0L,
    snapshot_dirty_age_ms: 0L,
    qos2_received: 0L,
    qos2_duplicates: 0L,
    qos2_rejected: 0L,
    started_at_ms,
    messages_received: 0L,
    messages_sent: 0L,
    messages_dropped: 0L,
    authentication_failures: 0L,
    auth_requests: 0L,
    auth_successes: 0L,
    auth_bad_credentials: 0L,
    auth_resource_rejections: 0L,
    auth_deadline_rejections: 0L,
    auth_late_results: 0L,
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
pub fn BrokerMetrics::auth_requests(self : BrokerMetrics) -> Int64 {
  self.auth_requests
}

///|
pub fn BrokerMetrics::auth_successes(self : BrokerMetrics) -> Int64 {
  self.auth_successes
}

///|
pub fn BrokerMetrics::auth_bad_credentials(self : BrokerMetrics) -> Int64 {
  self.auth_bad_credentials
}

///|
pub fn BrokerMetrics::auth_resource_rejections(self : BrokerMetrics) -> Int64 {
  self.auth_resource_rejections
}

///|
pub fn BrokerMetrics::auth_deadline_rejections(self : BrokerMetrics) -> Int64 {
  self.auth_deadline_rejections
}

///|
pub fn BrokerMetrics::auth_late_results(self : BrokerMetrics) -> Int64 {
  self.auth_late_results
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
fn saturating_counter_increment(value : Int64) -> Int64 {
  if value == 9223372036854775807L {
    value
  } else {
    value + 1L
  }
}

///|
fn BrokerMetrics::record_received(self : BrokerMetrics) -> Unit {
  self.messages_received = saturating_counter_increment(self.messages_received)
}

///|
fn BrokerMetrics::record_sent(self : BrokerMetrics) -> Unit {
  self.messages_sent = saturating_counter_increment(self.messages_sent)
}

///|
fn BrokerMetrics::record_dropped(self : BrokerMetrics) -> Unit {
  self.messages_dropped = saturating_counter_increment(self.messages_dropped)
}

///|
fn BrokerMetrics::record_auth_request(self : BrokerMetrics) -> Unit {
  self.auth_requests = saturating_counter_increment(self.auth_requests)
}

///|
fn BrokerMetrics::record_auth_success(self : BrokerMetrics) -> Unit {
  self.auth_successes = saturating_counter_increment(self.auth_successes)
}

///|
fn BrokerMetrics::record_auth_bad_credentials(self : BrokerMetrics) -> Unit {
  self.auth_bad_credentials = saturating_counter_increment(
    self.auth_bad_credentials,
  )
}

///|
fn BrokerMetrics::record_auth_resource_rejection(self : BrokerMetrics) -> Unit {
  self.auth_resource_rejections = saturating_counter_increment(
    self.auth_resource_rejections,
  )
}

///|
fn BrokerMetrics::record_auth_deadline_rejection(self : BrokerMetrics) -> Unit {
  self.auth_deadline_rejections = saturating_counter_increment(
    self.auth_deadline_rejections,
  )
}

///|
fn BrokerMetrics::record_auth_late_result(self : BrokerMetrics) -> Unit {
  self.auth_late_results = saturating_counter_increment(self.auth_late_results)
}

///|
fn BrokerMetrics::record_authentication_failure(self : BrokerMetrics) -> Unit {
  self.authentication_failures = saturating_counter_increment(
    self.authentication_failures,
  )
}

///|
fn BrokerMetrics::record_acl_denial(self : BrokerMetrics) -> Unit {
  self.acl_denials = saturating_counter_increment(self.acl_denials)
}

///|
pub fn BrokerMetrics::record_tls_handshake_failure(
  self : BrokerMetrics,
) -> Unit {
  self.tls_handshake_failures = saturating_counter_increment(
    self.tls_handshake_failures,
  )
}

///|
pub fn BrokerMetrics::qos2_received(self : BrokerMetrics) -> Int64 {
  self.qos2_received
}

///|
pub fn BrokerMetrics::qos2_duplicates(self : BrokerMetrics) -> Int64 {
  self.qos2_duplicates
}

///|
pub fn BrokerMetrics::qos2_rejected(self : BrokerMetrics) -> Int64 {
  self.qos2_rejected
}

///|
fn BrokerMetrics::record_qos2(self : BrokerMetrics, duplicate~ : Bool) -> Unit {
  self.qos2_received = saturating_counter_increment(self.qos2_received)
  if duplicate {
    self.qos2_duplicates = saturating_counter_increment(self.qos2_duplicates)
  }
}

///|
fn BrokerMetrics::record_qos2_rejection(self : BrokerMetrics) -> Unit {
  self.qos2_rejected = saturating_counter_increment(self.qos2_rejected)
}
