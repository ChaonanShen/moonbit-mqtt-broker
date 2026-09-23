///|
fn status_persistence_mode(value : PersistenceMode) -> String {
  match value {
    Off => "off"
    Snapshot => "snapshot"
    Strict => "strict"
  }
}

///|
fn status_persistence_state(value : PersistenceState) -> String {
  match value {
    Disabled => "disabled"
    Healthy => "healthy"
    Degraded => "degraded"
    Recovering => "recovering"
    Fenced => "fenced"
  }
}

///|
fn status_lifecycle(value : ServiceLifecycle) -> String {
  match value {
    Starting => "starting"
    Serving => "serving"
    Stopping => "stopping"
    Failed => "failed"
  }
}

///|
fn json_decimal(value : Int64) -> Json {
  @json.to_json(value.to_string())
}

///|
fn json_optional_decimal(value : Int64?) -> Json {
  match value {
    Some(number) => json_decimal(number)
    None => @json.to_json(())
  }
}

///|
/// Public status contains no session, client, topic, principal, credential,
/// file path or payload. All Int64 values are decimal JSON strings.
pub fn encode_status(
  sample : ObservationSnapshot,
  now_monotonic_ms : Int64,
  snapshot_max_age_ms : Int64,
  driver_max_age_ms : Int64,
  driver_progress_override? : Int64,
  details_enabled? : Bool = false,
  operations_enabled? : Bool = false,
  details_available? : Bool = false,
) -> Bytes {
  let health = evaluate_health(
    sample,
    now_monotonic_ms,
    snapshot_max_age_ms,
    driver_max_age_ms,
    driver_progress_override?,
  )
  let observed_age : Int64? = if now_monotonic_ms >=
    sample.captured_monotonic_ms &&
    sample.captured_monotonic_ms >= 0L {
    Some(now_monotonic_ms - sample.captured_monotonic_ms)
  } else {
    None
  }
  let mqtt : Map[String, Json] = Map([
    ("connections_registered", json_decimal(sample.connections_registered)),
    ("connections_active", json_decimal(sample.connections_active)),
    ("auth_tasks_outstanding", json_decimal(sample.auth_tasks_outstanding)),
    ("sessions", json_decimal(sample.sessions_total)),
    ("subscriptions", json_decimal(sample.subscriptions_total)),
    ("retained", json_decimal(sample.retained_total)),
    ("inflight", json_decimal(sample.inflight_total)),
    ("pending", json_decimal(sample.pending_total)),
    ("inbound_qos2", json_decimal(sample.inbound_qos2_total)),
  ])
  let persistence : Map[String, Json] = Map([
    ("mode", @json.to_json(status_persistence_mode(sample.persistence_mode))),
    ("state", @json.to_json(status_persistence_state(sample.persistence_state))),
    ("state_revision", json_decimal(sample.state_revision)),
    (
      "committed_revision",
      json_optional_decimal(sample.snapshot_committed_revision),
    ),
    ("dirty_age_ms", json_decimal(sample.snapshot_dirty_age_ms)),
    ("budget_deferred", json_decimal(sample.snapshot_budget_deferred)),
    ("committed_lsn", json_optional_decimal(sample.committed_lsn)),
    ("applied_lsn", json_optional_decimal(sample.applied_lsn)),
    ("checkpoint_lsn", json_optional_decimal(sample.checkpoint_lsn)),
    ("wal_pending_transactions", json_decimal(sample.wal_pending_transactions)),
    ("wal_pending_bytes", json_decimal(sample.wal_pending_bytes)),
  ])
  let resources : Map[String, Json] = Map([
    ("committed_bytes", json_decimal(sample.resource_total_committed)),
    ("reserved_bytes", json_decimal(sample.resource_total_reserved)),
    ("limit_bytes", json_decimal(sample.resource_total_limit)),
    ("rejections_total", json_decimal(sample.resource_rejections_total)),
  ])
  let categories : Array[Json] = []
  for entry in sample.resources {
    let row : Map[String, Json] = Map([
      ("name", @json.to_json(entry.name)),
      ("committed_bytes", json_decimal(entry.committed_bytes)),
      ("reserved_bytes", json_decimal(entry.reserved_bytes)),
      ("limit_bytes", json_decimal(entry.limit_bytes)),
    ])
    categories.push(@json.to_json(row))
  }
  resources.set("categories", @json.to_json(categories))
  let counters : Map[String, Json] = Map([
    ("messages_received", json_decimal(sample.messages_received)),
    ("messages_sent", json_decimal(sample.messages_sent)),
    ("messages_dropped", json_decimal(sample.messages_dropped)),
    ("qos2_received", json_decimal(sample.qos2_received)),
    ("qos2_duplicates", json_decimal(sample.qos2_duplicates)),
    ("qos2_rejected", json_decimal(sample.qos2_rejected)),
    ("auth_requests", json_decimal(sample.auth_requests)),
    ("auth_successes", json_decimal(sample.auth_successes)),
    ("auth_bad_credentials", json_decimal(sample.auth_bad_credentials)),
    ("auth_resource_rejections", json_decimal(sample.auth_resource_rejections)),
    ("auth_deadline_rejections", json_decimal(sample.auth_deadline_rejections)),
    ("auth_late_results", json_decimal(sample.auth_late_results)),
    ("auth_failures", json_decimal(sample.auth_failures)),
    ("acl_denials", json_decimal(sample.acl_denials)),
    ("tls_handshake_failures", json_decimal(sample.tls_handshake_failures)),
  ])
  let capabilities : Map[String, Json] = Map([
    ("details", details_enabled.to_json()),
    ("operations", operations_enabled.to_json()),
    ("reload", false.to_json()),
    (
      "completion_scope",
      (if sample.persistence_mode == Strict { "durable" } else { "runtime" }).to_json(),
    ),
  ])
  let root : Map[String, Json] = Map([
    ("api_version", @json.to_json("1")),
    ("boot_id", @json.to_json(sample.boot_id)),
    ("version", @json.to_json(sample.version)),
    ("observed_at_ms", json_decimal(sample.captured_unix_ms)),
    ("observation_age_ms", json_optional_decimal(observed_age)),
    ("uptime_seconds", json_decimal(sample.uptime_seconds(now_monotonic_ms))),
    ("lifecycle", @json.to_json(status_lifecycle(sample.lifecycle))),
    ("ready", @json.to_json(health.ready)),
    ("reasons", @json.to_json(health.reasons)),
    ("mqtt", @json.to_json(mqtt)),
    ("persistence", @json.to_json(persistence)),
    ("resources", @json.to_json(resources)),
    ("counters", @json.to_json(counters)),
    ("capabilities", capabilities.to_json()),
    ("details_available", details_available.to_json()),
  ])
  @utf8.encode(@json.to_json(root).stringify())
}

///|
pub fn encode_health_live(decision : HealthDecision) -> Bytes {
  @utf8.encode(
    if decision.live {
      "{\"status\":\"live\"}"
    } else {
      "{\"status\":\"unavailable\"}"
    },
  )
}

///|
pub fn encode_health_ready(decision : HealthDecision) -> Bytes {
  @utf8.encode(
    if decision.ready {
      "{\"status\":\"ready\"}"
    } else {
      "{\"status\":\"unavailable\"}"
    },
  )
}
