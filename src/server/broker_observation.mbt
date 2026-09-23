///|
/// Only scalar values used by $SYS and management. No Session iteration,
/// snapshot export, QoS phase filter or payload copy occurs here.
priv struct BrokerBaseObservation {
  uptime_seconds : Int64
  connections_registered : Int64
  clients_connected : Int64
  sessions_total : Int64
  subscriptions_total : Int64
  retained_total : Int64
  inflight_total : Int64
  pending_total : Int64
  inbound_qos2_total : Int64
  messages_received : Int64
  messages_sent : Int64
  messages_dropped : Int64
  qos2_received : Int64
  qos2_duplicates : Int64
  qos2_rejected : Int64
  auth_failures : Int64
  auth_requests : Int64
  auth_successes : Int64
  auth_bad_credentials : Int64
  auth_resource_rejections : Int64
  auth_deadline_rejections : Int64
  auth_late_results : Int64
  auth_tasks_outstanding : Int64
  acl_denials : Int64
  tls_handshake_failures : Int64
  resource_committed : Int64
  resource_reserved : Int64
  resource_rejections : Int64
  snapshot_budget_deferred : Int64
  snapshot_dirty_age_ms : Int64
}

///|
fn BrokerRuntime::collect_base_observation(
  self : BrokerRuntime,
  now_wall_ms : Int64,
) -> BrokerBaseObservation {
  let state = self.broker_state
  let ledger = state.resource_ledger()
  {
    uptime_seconds: self.metrics.uptime_seconds(now_wall_ms),
    connections_registered: self.connections.length().to_int64(),
    clients_connected: self.active_by_client.length().to_int64(),
    sessions_total: state.session_count().to_int64(),
    subscriptions_total: state.subscription_count().to_int64(),
    retained_total: state.retained_count().to_int64(),
    inflight_total: state.inflight_count().to_int64(),
    pending_total: state.pending_qos1_count().to_int64(),
    inbound_qos2_total: state.inbound_qos2_count().to_int64(),
    messages_received: self.metrics.messages_received(),
    messages_sent: self.metrics.messages_sent(),
    messages_dropped: self.metrics.messages_dropped(),
    qos2_received: self.metrics.qos2_received(),
    qos2_duplicates: self.metrics.qos2_duplicates(),
    qos2_rejected: self.metrics.qos2_rejected(),
    auth_failures: self.metrics.authentication_failures(),
    auth_requests: self.metrics.auth_requests(),
    auth_successes: self.metrics.auth_successes(),
    auth_bad_credentials: self.metrics.auth_bad_credentials(),
    auth_resource_rejections: self.metrics.auth_resource_rejections(),
    auth_deadline_rejections: self.metrics.auth_deadline_rejections(),
    auth_late_results: self.metrics.auth_late_results(),
    auth_tasks_outstanding: self.auth_tasks.length().to_int64(),
    acl_denials: self.metrics.acl_denials(),
    tls_handshake_failures: self.metrics.tls_handshake_failures(),
    resource_committed: ledger.committed(),
    resource_reserved: ledger.reserved(),
    resource_rejections: ledger.rejections_total(),
    snapshot_budget_deferred: self.metrics.snapshot_budget_deferred,
    snapshot_dirty_age_ms: self.metrics.snapshot_dirty_age_ms,
  }
}
