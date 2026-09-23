///|
pub(all) enum PersistenceMode {
  Off
  Snapshot
} derive(Eq, Debug)

///|
pub(all) enum PersistenceState {
  Disabled
  Healthy
  Degraded
} derive(Eq, Debug)

///|
pub(all) enum ServiceLifecycle {
  Starting
  Serving
  Stopping
  Failed
} derive(Eq, Debug)

///|
pub(all) struct ResourceObservation {
  name : String
  committed_bytes : Int64
  reserved_bytes : Int64
  limit_bytes : Int64
}

///|
/// Immutable by convention after capture. These fields contain only fixed
/// counters/enums; no Session, payload, token database, principal or path.
pub(all) struct ObservationSnapshot {
  boot_id : String
  version : String
  boot_monotonic_ms : Int64
  captured_monotonic_ms : Int64
  captured_unix_ms : Int64
  driver_progress_monotonic_ms : Int64
  connections_registered : Int64
  connections_active : Int64
  auth_tasks_outstanding : Int64
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
  auth_requests : Int64
  auth_successes : Int64
  auth_bad_credentials : Int64
  auth_resource_rejections : Int64
  auth_deadline_rejections : Int64
  auth_late_results : Int64
  auth_failures : Int64
  acl_denials : Int64
  tls_handshake_failures : Int64
  resource_total_committed : Int64
  resource_total_reserved : Int64
  resource_total_limit : Int64
  resource_rejections_total : Int64
  resources : Array[ResourceObservation]
  persistence_mode : PersistenceMode
  persistence_state : PersistenceState
  state_revision : Int64
  snapshot_committed_revision : Int64?
  snapshot_dirty_age_ms : Int64
  snapshot_budget_deferred : Int64
  lifecycle : ServiceLifecycle
  mqtt_listener_up : Bool
  management_listener_up : Bool
  ready_require_snapshot_healthy : Bool
}

///|
pub(all) struct HealthDecision {
  live : Bool
  ready : Bool
  reasons : Array[String]
}

///|
pub fn ObservationSnapshot::uptime_seconds(
  self : ObservationSnapshot,
  now_monotonic_ms : Int64,
) -> Int64 {
  if self.boot_monotonic_ms < 0L || now_monotonic_ms < self.boot_monotonic_ms {
    0L
  } else {
    (now_monotonic_ms - self.boot_monotonic_ms) / 1000L
  }
}

///|
/// All ages use one monotonic clock. Reasons are fixed strings and never
/// include paths, error text or client identifiers.
pub fn evaluate_health(
  sample : ObservationSnapshot,
  now_monotonic_ms : Int64,
  snapshot_max_age_ms : Int64,
  driver_max_age_ms : Int64,
) -> HealthDecision {
  let reasons : Array[String] = []
  let mut live = true
  let mut ready = true
  if sample.lifecycle == Starting || sample.lifecycle == Failed {
    live = false
    ready = false
    reasons.push("not_serving")
  }
  if sample.lifecycle == Stopping {
    ready = false
    reasons.push("stopping")
  }
  if now_monotonic_ms < 0L ||
    sample.captured_monotonic_ms < 0L ||
    sample.driver_progress_monotonic_ms < 0L ||
    now_monotonic_ms < sample.captured_monotonic_ms ||
    now_monotonic_ms < sample.driver_progress_monotonic_ms ||
    snapshot_max_age_ms < 0L ||
    driver_max_age_ms < 0L {
    live = false
    ready = false
    reasons.push("clock_unavailable")
    return { live, ready, reasons }
  }
  if now_monotonic_ms - sample.driver_progress_monotonic_ms > driver_max_age_ms {
    live = false
    ready = false
    reasons.push("driver_stale")
  }
  if now_monotonic_ms - sample.captured_monotonic_ms > snapshot_max_age_ms {
    ready = false
    reasons.push("observation_stale")
  }
  if !sample.mqtt_listener_up || !sample.management_listener_up {
    ready = false
    reasons.push("listener_down")
  }
  if sample.persistence_state == Degraded &&
    sample.ready_require_snapshot_healthy {
    ready = false
    reasons.push("snapshot_degraded")
  }
  { live, ready, reasons }
}
