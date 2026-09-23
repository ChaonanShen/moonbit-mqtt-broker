///|
pub(all) enum ManagementRejectReason {
  RejectedParse
  RejectedAuth
  RejectedRole
  RejectedRate
  RejectedCapacity
  RejectedDeadline
  RejectedStale
  RejectedOther
} derive(Eq, Debug)

///|
pub struct ManagementRejections {
  counts : Array[Int64]
}

///|
pub fn ManagementRejections::new() -> ManagementRejections {
  { counts: Array::make(8, 0L) }
}

///|
fn ManagementRejectReason::index(self : ManagementRejectReason) -> Int {
  match self {
    RejectedParse => 0
    RejectedAuth => 1
    RejectedRole => 2
    RejectedRate => 3
    RejectedCapacity => 4
    RejectedDeadline => 5
    RejectedStale => 6
    RejectedOther => 7
  }
}

///|
pub fn ManagementRejections::record(
  self : ManagementRejections,
  reason : ManagementRejectReason,
) -> Unit {
  let index = reason.index()
  if self.counts[index] < 9223372036854775807L {
    self.counts[index] = self.counts[index] + 1L
  }
}

///|
pub fn ManagementRejections::value(
  self : ManagementRejections,
  reason : ManagementRejectReason,
) -> Int64 {
  self.counts[reason.index()]
}

///|
pub(all) enum PrometheusError {
  InvalidClock
  InvalidResource
  TooManySeries
} derive(Eq, Debug)

///|
fn prometheus_seconds(ms : Int64) -> String {
  let seconds = ms / 1000L
  let fraction = ms % 1000L
  let suffix = if fraction < 10L {
    "00" + fraction.to_string()
  } else if fraction < 100L {
    "0" + fraction.to_string()
  } else {
    fraction.to_string()
  }
  seconds.to_string() + "." + suffix
}

///|
fn prometheus_label(value : String) -> String {
  value
  .replace_all(old="\\", new="\\\\")
  .replace_all(old="\"", new="\\\"")
  .replace_all(old="\n", new="\\n")
}

///|
fn add_family(
  lines : Array[String],
  suffix : String,
  help : String,
  kind : String,
) -> String {
  let name = "moonbit_mqtt_broker_" + suffix
  lines.push("# HELP " + name + " " + help)
  lines.push("# TYPE " + name + " " + kind)
  name
}

///|
fn add_scalar(
  lines : Array[String],
  suffix : String,
  help : String,
  value : String,
  counter : Bool,
) -> Unit {
  let name = add_family(
    lines,
    suffix,
    help,
    if counter {
      "counter"
    } else {
      "gauge"
    },
  )
  lines.push(name + " " + value)
}

///|
fn fixed_resource_kinds() -> Array[@budget.ResourceKind] {
  [
    @budget.ResourceKind::Receive,
    @budget.ResourceKind::RuntimeEvent,
    @budget.ResourceKind::Inflight,
    @budget.ResourceKind::Pending,
    @budget.ResourceKind::InboundQoS2,
    @budget.ResourceKind::Retained,
    @budget.ResourceKind::Will,
    @budget.ResourceKind::Subscription,
    @budget.ResourceKind::SessionMetadata,
    @budget.ResourceKind::Outbound,
    @budget.ResourceKind::Routing,
    @budget.ResourceKind::Snapshot,
    @budget.ResourceKind::WalPending,
    @budget.ResourceKind::AuthRequest,
    @budget.ResourceKind::AuthWorkspace,
    @budget.ResourceKind::AuthResult,
    @budget.ResourceKind::ConnectionMetadata,
    @budget.ResourceKind::LimiterMetadata,
    @budget.ResourceKind::Infrastructure,
    @budget.ResourceKind::ControlEvent,
    @budget.ResourceKind::ControlRuntime,
    @budget.ResourceKind::ControlFrame,
    @budget.ResourceKind::ControlWork,
    @budget.ResourceKind::ManagementInfrastructure,
    @budget.ResourceKind::ManagementRequest,
    @budget.ResourceKind::ManagementCache,
    @budget.ResourceKind::ManagementIndex,
    @budget.ResourceKind::ManagementQuery,
    @budget.ResourceKind::ManagementCursor,
    @budget.ResourceKind::ManagementOperation,
    @budget.ResourceKind::ManagementAudit,
  ]
}

///|
/// Bounded fixed-name/label Prometheus text 0.0.4. No client, topic, IP,
/// token ID, boot ID or request ID can become a label.
pub fn render_prometheus(
  sample : ObservationSnapshot,
  now_monotonic_ms : Int64,
  driver_progress_monotonic_ms : Int64,
  rejections : ManagementRejections,
) -> Result[Bytes, PrometheusError] {
  if now_monotonic_ms < 0L ||
    sample.captured_monotonic_ms < 0L ||
    driver_progress_monotonic_ms < 0L ||
    now_monotonic_ms < sample.captured_monotonic_ms ||
    now_monotonic_ms < driver_progress_monotonic_ms {
    return Err(InvalidClock)
  }
  let lines : Array[String] = []
  let build = add_family(
    lines, "build_info", "Broker build information", "gauge",
  )
  lines.push(
    build +
    "{version=\"" +
    prometheus_label(sample.version) +
    "\",target=\"native\"} 1",
  )
  add_scalar(
    lines,
    "uptime_seconds",
    "Process uptime in seconds",
    sample.uptime_seconds(now_monotonic_ms).to_string(),
    false,
  )
  add_scalar(
    lines,
    "connections_registered",
    "Registered MQTT transports",
    sample.connections_registered.to_string(),
    false,
  )
  add_scalar(
    lines,
    "connections_active",
    "Active MQTT connections",
    sample.connections_active.to_string(),
    false,
  )
  add_scalar(
    lines,
    "sessions",
    "Broker sessions",
    sample.sessions_total.to_string(),
    false,
  )
  add_scalar(
    lines,
    "subscriptions",
    "Installed subscriptions",
    sample.subscriptions_total.to_string(),
    false,
  )
  add_scalar(
    lines,
    "retained_messages",
    "Retained messages",
    sample.retained_total.to_string(),
    false,
  )
  add_scalar(
    lines,
    "outbound_inflight",
    "Outbound QoS 1 and 2 inflight messages",
    sample.inflight_total.to_string(),
    false,
  )
  add_scalar(
    lines,
    "outbound_pending",
    "Outbound QoS 1 and 2 pending messages",
    sample.pending_total.to_string(),
    false,
  )
  add_scalar(
    lines,
    "qos2_inbound",
    "Inbound QoS 2 exchange states",
    sample.inbound_qos2_total.to_string(),
    false,
  )
  add_scalar(
    lines,
    "publish_packets_received_total",
    "PUBLISH packets processed",
    sample.messages_received.to_string(),
    true,
  )
  add_scalar(
    lines,
    "publish_actions_total",
    "Downstream publish actions created",
    sample.messages_sent.to_string(),
    true,
  )
  add_scalar(
    lines,
    "delivery_dropped_total",
    "Dropped deliveries",
    sample.messages_dropped.to_string(),
    true,
  )
  add_scalar(
    lines,
    "qos2_received_total",
    "QoS 2 inbound packets received",
    sample.qos2_received.to_string(),
    true,
  )
  add_scalar(
    lines,
    "qos2_duplicates_total",
    "QoS 2 duplicate packets",
    sample.qos2_duplicates.to_string(),
    true,
  )
  add_scalar(
    lines,
    "qos2_rejected_total",
    "QoS 2 rejected packets",
    sample.qos2_rejected.to_string(),
    true,
  )
  add_scalar(
    lines,
    "auth_requests_total",
    "Authentication attempts",
    sample.auth_requests.to_string(),
    true,
  )
  add_scalar(
    lines,
    "auth_successes_total",
    "Successful authentications",
    sample.auth_successes.to_string(),
    true,
  )
  add_scalar(
    lines,
    "auth_failures_total",
    "Failed authentications",
    sample.auth_failures.to_string(),
    true,
  )
  add_scalar(
    lines,
    "auth_bad_credentials_total",
    "Bad credential decisions",
    sample.auth_bad_credentials.to_string(),
    true,
  )
  add_scalar(
    lines,
    "auth_resource_rejections_total",
    "Authentication resource rejections",
    sample.auth_resource_rejections.to_string(),
    true,
  )
  add_scalar(
    lines,
    "auth_deadline_rejections_total",
    "Authentication deadline rejections",
    sample.auth_deadline_rejections.to_string(),
    true,
  )
  add_scalar(
    lines,
    "auth_late_results_total",
    "Late authentication results",
    sample.auth_late_results.to_string(),
    true,
  )
  add_scalar(
    lines,
    "auth_tasks_outstanding",
    "Unreaped authentication tasks",
    sample.auth_tasks_outstanding.to_string(),
    false,
  )
  add_scalar(
    lines,
    "acl_denials_total",
    "ACL denials",
    sample.acl_denials.to_string(),
    true,
  )
  add_scalar(
    lines,
    "tls_handshake_failures_total",
    "TLS handshake failures",
    sample.tls_handshake_failures.to_string(),
    true,
  )
  add_scalar(
    lines,
    "managed_committed_bytes",
    "Managed committed bytes",
    sample.resource_total_committed.to_string(),
    false,
  )
  add_scalar(
    lines,
    "managed_reserved_bytes",
    "Managed reserved bytes",
    sample.resource_total_reserved.to_string(),
    false,
  )
  add_scalar(
    lines,
    "managed_limit_bytes",
    "Managed global byte limit",
    sample.resource_total_limit.to_string(),
    false,
  )
  add_scalar(
    lines,
    "resource_rejections_total",
    "Resource budget rejections",
    sample.resource_rejections_total.to_string(),
    true,
  )
  add_scalar(
    lines,
    "snapshot_dirty_age_seconds",
    "Age of uncommitted snapshot state in seconds",
    prometheus_seconds(sample.snapshot_dirty_age_ms),
    false,
  )
  add_scalar(
    lines,
    "snapshot_budget_deferred_total",
    "Snapshots deferred by budget",
    sample.snapshot_budget_deferred.to_string(),
    true,
  )
  let resources = fixed_resource_kinds()
  for row in sample.resources {
    let mut allowed = false
    for kind in resources {
      if row.name == kind.name() {
        allowed = true
      }
    }
    if !allowed {
      return Err(InvalidResource)
    }
  }
  for
    descriptor in [
      ("resource_committed_bytes", "Committed bytes by fixed resource kind"),
      ("resource_reserved_bytes", "Reserved bytes by fixed resource kind"),
      ("resource_limit_bytes", "Byte cap by fixed resource kind"),
    ] {
    let (suffix, help) = descriptor
    let name = add_family(lines, suffix, help, "gauge")
    for kind in resources {
      let resource_name = kind.name()
      let mut found = false
      for row in sample.resources {
        if row.name == resource_name {
          if found {
            return Err(InvalidResource)
          }
          found = true
          let value = match suffix {
            "resource_committed_bytes" => row.committed_bytes
            "resource_reserved_bytes" => row.reserved_bytes
            _ => row.limit_bytes
          }
          lines.push(
            name +
            "{resource=\"" +
            prometheus_label(resource_name) +
            "\"} " +
            value.to_string(),
          )
        }
      }
    }
  }
  add_scalar(
    lines,
    "wal_committed_lsn",
    "Last synced WAL LSN",
    sample.committed_lsn.unwrap_or(0L).to_string(),
    false,
  )
  add_scalar(
    lines,
    "wal_applied_lsn",
    "Last applied WAL LSN",
    sample.applied_lsn.unwrap_or(0L).to_string(),
    false,
  )
  add_scalar(
    lines,
    "wal_checkpoint_lsn",
    "Published WAL checkpoint LSN",
    sample.checkpoint_lsn.unwrap_or(0L).to_string(),
    false,
  )
  add_scalar(
    lines,
    "wal_pending_transactions",
    "Uncommitted WAL transactions",
    sample.wal_pending_transactions.to_string(),
    false,
  )
  add_scalar(
    lines,
    "wal_pending_bytes",
    "Uncommitted WAL bytes",
    sample.wal_pending_bytes.to_string(),
    false,
  )
  let state = add_family(
    lines, "snapshot_state", "Snapshot persistence state", "gauge",
  )
  for
    item in [
      ("disabled", PersistenceState::Disabled),
      ("healthy", PersistenceState::Healthy),
      ("degraded", PersistenceState::Degraded),
      ("recovering", PersistenceState::Recovering),
      ("fenced", PersistenceState::Fenced),
    ] {
    let (label, candidate) = item
    lines.push(
      state +
      "{state=\"" +
      label +
      "\"} " +
      (if sample.persistence_state == candidate { "1" } else { "0" }),
    )
  }
  let rejected = add_family(
    lines, "management_rejected_total", "Rejected management requests", "counter",
  )
  for
    item in [
      ("parse", RejectedParse),
      ("auth", RejectedAuth),
      ("role", RejectedRole),
      ("rate", RejectedRate),
      ("capacity", RejectedCapacity),
      ("deadline", RejectedDeadline),
      ("stale", RejectedStale),
      ("other", RejectedOther),
    ] {
    let (label, reason) = item
    lines.push(
      rejected +
      "{reason=\"" +
      label +
      "\"} " +
      rejections.value(reason).to_string(),
    )
  }
  add_scalar(
    lines,
    "observation_age_seconds",
    "Age of cached observation in seconds",
    prometheus_seconds(now_monotonic_ms - sample.captured_monotonic_ms),
    false,
  )
  add_scalar(
    lines,
    "driver_progress_age_seconds",
    "Age of driver progress in seconds",
    prometheus_seconds(now_monotonic_ms - driver_progress_monotonic_ms),
    false,
  )
  let mut series = 0
  for line in lines {
    if !line.has_prefix("#") {
      series += 1
    }
  }
  if series > 256 {
    return Err(TooManySeries)
  }
  Ok(@utf8.encode(lines.join("\n") + "\n"))
}

///|
/// Startup sizing fixture: all fixed families/categories and the largest
/// decimal counters, status fields and age values. This is constructed before
/// listener readiness; smaller configured responses fail closed.
pub fn worst_case_response_bytes() -> Int {
  let max = 9223372036854775807L
  let rows : Array[ResourceObservation] = []
  for kind in fixed_resource_kinds() {
    rows.push({
      name: kind.name(),
      committed_bytes: max,
      reserved_bytes: max,
      limit_bytes: max,
    })
  }
  let sample : ObservationSnapshot = {
    boot_id: "0123456789abcdef0123456789abcdef",
    version: "0.2.0",
    boot_monotonic_ms: 0L,
    captured_monotonic_ms: 0L,
    captured_unix_ms: max,
    driver_progress_monotonic_ms: 0L,
    connections_registered: max,
    connections_active: max,
    auth_tasks_outstanding: max,
    sessions_total: max,
    subscriptions_total: max,
    retained_total: max,
    inflight_total: max,
    pending_total: max,
    inbound_qos2_total: max,
    qos2_received: max,
    qos2_duplicates: max,
    qos2_rejected: max,
    messages_received: max,
    messages_sent: max,
    messages_dropped: max,
    auth_requests: max,
    auth_successes: max,
    auth_bad_credentials: max,
    auth_resource_rejections: max,
    auth_deadline_rejections: max,
    auth_late_results: max,
    auth_failures: max,
    acl_denials: max,
    tls_handshake_failures: max,
    resource_total_committed: max,
    resource_total_reserved: max,
    resource_total_limit: max,
    resource_rejections_total: max,
    resources: rows,
    persistence_mode: PersistenceMode::Snapshot,
    persistence_state: PersistenceState::Degraded,
    state_revision: max,
    snapshot_committed_revision: Some(max),
    committed_lsn: Some(max),
    applied_lsn: Some(max),
    checkpoint_lsn: Some(max),
    wal_pending_transactions: max,
    wal_pending_bytes: max,
    snapshot_dirty_age_ms: max,
    snapshot_budget_deferred: max,
    lifecycle: ServiceLifecycle::Failed,
    mqtt_listener_up: false,
    management_listener_up: false,
    ready_require_snapshot_healthy: true,
  }
  let rejected = ManagementRejections::new()
  for index in 0..<rejected.counts.length() {
    rejected.counts[index] = max
  }
  let metrics = render_prometheus(sample, max, 0L, rejected).unwrap()
  let status = encode_status(sample, max, 60000L, 60000L)
  if metrics.length() > status.length() {
    metrics.length()
  } else {
    status.length()
  }
}
