///|
pub(all) struct ObservationContext {
  boot_id : String
  boot_monotonic_ms : Int64
  lifecycle : @management.ServiceLifecycle
  mqtt_listener_up : Bool
  management_listener_up : Bool
  ready_require_snapshot_healthy : Bool
}

///|
/// Captures only typed counters and the bounded Ledger category table.
/// This path does not export a disk snapshot, scan sessions or publish $SYS.
pub fn RouterDriver::capture_observation(
  self : RouterDriver,
  now_monotonic_ms : Int64,
  now_unix_ms : Int64,
  context : ObservationContext,
  persistence? : PersistenceRuntime,
) -> @management.ObservationSnapshot {
  let runtime = self.runtime
  let state = runtime.broker_state()
  let base = runtime.collect_base_observation(now_unix_ms)
  let ledger = state.resource_ledger()
  let resource_rows : Array[@management.ResourceObservation] = []
  for entry in ledger.usage() {
    let (kind, committed, reserved, limit) = entry
    resource_rows.push(@management.ResourceObservation::{
      name: kind.name(),
      committed_bytes: committed,
      reserved_bytes: reserved,
      limit_bytes: limit,
    })
  }
  let persistence_mode = match self.strict {
    Some(_) => @management.PersistenceMode::Strict
    None =>
      match persistence {
        None => @management.PersistenceMode::Off
        Some(_) => @management.PersistenceMode::Snapshot
      }
  }
  let persistence_state = match self.strict {
    Some(coordinator) =>
      if self.strict_fenced || coordinator.is_fenced() {
        @management.PersistenceState::Fenced
      } else if self.strict_checkpoint_degraded {
        @management.PersistenceState::Degraded
      } else {
        @management.PersistenceState::Healthy
      }
    None =>
      match persistence {
        None => @management.PersistenceState::Disabled
        Some(runtime) =>
          if runtime.is_degraded() {
            @management.PersistenceState::Degraded
          } else {
            @management.PersistenceState::Healthy
          }
      }
  }
  let committed = match persistence {
    None => None
    Some(runtime) =>
      if runtime.committed_revision() < 0L {
        None
      } else {
        Some(runtime.committed_revision())
      }
  }
  {
    boot_id: context.boot_id,
    version: "0.3.0",
    boot_monotonic_ms: context.boot_monotonic_ms,
    captured_monotonic_ms: now_monotonic_ms,
    captured_unix_ms: now_unix_ms,
    driver_progress_monotonic_ms: self.last_progress_monotonic_ms,
    connections_registered: base.connections_registered,
    connections_active: base.clients_connected,
    auth_tasks_outstanding: base.auth_tasks_outstanding,
    sessions_total: base.sessions_total,
    subscriptions_total: base.subscriptions_total,
    retained_total: base.retained_total,
    inflight_total: base.inflight_total,
    pending_total: base.pending_total,
    inbound_qos2_total: base.inbound_qos2_total,
    messages_received: base.messages_received,
    messages_sent: base.messages_sent,
    messages_dropped: base.messages_dropped,
    qos2_received: base.qos2_received,
    qos2_duplicates: base.qos2_duplicates,
    qos2_rejected: base.qos2_rejected,
    auth_requests: base.auth_requests,
    auth_successes: base.auth_successes,
    auth_bad_credentials: base.auth_bad_credentials,
    auth_resource_rejections: base.auth_resource_rejections,
    auth_deadline_rejections: base.auth_deadline_rejections,
    auth_late_results: base.auth_late_results,
    auth_failures: base.auth_failures,
    acl_denials: base.acl_denials,
    tls_handshake_failures: base.tls_handshake_failures,
    resource_total_committed: base.resource_committed,
    resource_total_reserved: base.resource_reserved,
    resource_total_limit: runtime.config
    .broker_config()
    .resources()
    .get("max_managed_bytes_total"),
    resource_rejections_total: base.resource_rejections,
    resources: resource_rows,
    persistence_mode,
    persistence_state,
    state_revision: state.snapshot_revision(),
    snapshot_committed_revision: committed,
    committed_lsn: self.strict.map(value => value.committed_lsn()),
    applied_lsn: self.strict.map(value => value.applied_lsn()),
    checkpoint_lsn: self.strict.map(value => value.checkpoint_lsn()),
    wal_pending_transactions: if self.strict is Some(value) &&
      value.has_pending() {
      1L
    } else {
      0L
    },
    wal_pending_bytes: self.strict
    .map(value => value.pending_bytes())
    .unwrap_or(0L),
    snapshot_dirty_age_ms: base.snapshot_dirty_age_ms,
    snapshot_budget_deferred: base.snapshot_budget_deferred,
    lifecycle: context.lifecycle,
    mqtt_listener_up: context.mqtt_listener_up,
    management_listener_up: context.management_listener_up,
    ready_require_snapshot_healthy: context.ready_require_snapshot_healthy,
  }
}
