///|
fn sample_observation() -> ObservationSnapshot {
  {
    boot_id: "fixture-boot",
    version: "0.2.0",
    boot_monotonic_ms: 0L,
    captured_monotonic_ms: 1000L,
    captured_unix_ms: 123000L,
    driver_progress_monotonic_ms: 1000L,
    connections_registered: 0L,
    connections_active: 0L,
    auth_tasks_outstanding: 0L,
    sessions_total: 0L,
    subscriptions_total: 0L,
    retained_total: 0L,
    inflight_total: 0L,
    pending_total: 0L,
    inbound_qos2_total: 0L,
    messages_received: 0L,
    messages_sent: 0L,
    messages_dropped: 0L,
    qos2_received: 0L,
    qos2_duplicates: 0L,
    qos2_rejected: 0L,
    auth_requests: 0L,
    auth_successes: 0L,
    auth_bad_credentials: 0L,
    auth_resource_rejections: 0L,
    auth_deadline_rejections: 0L,
    auth_late_results: 0L,
    auth_failures: 0L,
    acl_denials: 0L,
    tls_handshake_failures: 0L,
    resource_total_committed: 0L,
    resource_total_reserved: 0L,
    resource_total_limit: 0L,
    resource_rejections_total: 0L,
    state_revision: 0L,
    snapshot_dirty_age_ms: 0L,
    snapshot_budget_deferred: 0L,
    resources: [],
    persistence_mode: Off,
    persistence_state: Disabled,
    snapshot_committed_revision: None,
    lifecycle: Serving,
    mqtt_listener_up: true,
    management_listener_up: true,
    ready_require_snapshot_healthy: false,
  }
}

///|
test "healthy observation has live and ready status" {
  let sample = sample_observation()
  let status = evaluate_health(sample, 1500L, 5000L, 5000L)
  assert_true(status.live)
  assert_true(status.ready)
  assert_eq(status.reasons, [])
  assert_eq(sample.uptime_seconds(1500L), 1L)
}

///|
test "stale cache removes readiness but not liveness" {
  let sample = sample_observation()
  let status = evaluate_health(sample, 7000L, 5000L, 10000L)
  assert_true(status.live)
  assert_false(status.ready)
  assert_eq(status.reasons, ["observation_stale"])
}

///|
test "stalled driver and clock regression cannot be healthy" {
  let sample = sample_observation()
  let stalled = evaluate_health(sample, 7000L, 10000L, 5000L)
  assert_false(stalled.live)
  assert_false(stalled.ready)
  assert_true(stalled.reasons.contains("driver_stale"))
  let reversed = evaluate_health(sample, 900L, 5000L, 5000L)
  assert_false(reversed.live)
  assert_false(reversed.ready)
  assert_eq(reversed.reasons, ["clock_unavailable"])
}

///|
test "degraded snapshot readiness is a fixed option" {
  let sample = {
    ..sample_observation(),
    persistence_mode: Snapshot,
    persistence_state: Degraded,
  }
  let optional = evaluate_health(sample, 1200L, 5000L, 5000L)
  assert_true(optional.ready)
  let required = evaluate_health(
    { ..sample, ready_require_snapshot_healthy: true },
    1200L,
    5000L,
    5000L,
  )
  assert_true(required.live)
  assert_false(required.ready)
  assert_true(required.reasons.contains("snapshot_degraded"))
}

///|
test "stopping and listener failures withdraw readiness" {
  let stopping = evaluate_health(
    { ..sample_observation(), lifecycle: Stopping },
    1200L,
    5000L,
    5000L,
  )
  assert_true(stopping.live)
  assert_false(stopping.ready)
  let down = evaluate_health(
    { ..sample_observation(), management_listener_up: false },
    1200L,
    5000L,
    5000L,
  )
  assert_true(down.live)
  assert_false(down.ready)
  assert_true(down.reasons.contains("listener_down"))
}

///|
test "status JSON exposes precise string counters and no secret fields" {
  let sample = {
    ..sample_observation(),
    sessions_total: 12L,
    messages_sent: 9007199254740993L,
    snapshot_committed_revision: Some(7L),
  }
  let json = @utf8.decode(encode_status(sample, 1500L, 5000L, 5000L)) catch {
    _ => fail("status was not UTF-8")
  }
  assert_true(json.contains("\"api_version\":\"1\""))
  assert_true(json.contains("\"sessions\":\"12\""))
  assert_true(json.contains("\"messages_sent\":\"9007199254740993\""))
  assert_true(json.contains("\"committed_revision\":\"7\""))
  assert_false(json.contains("token"))
  assert_false(json.contains("payload"))
  assert_false(json.contains("password"))
  let off = @utf8.decode(
    encode_status(sample_observation(), 1500L, 5000L, 5000L),
  ) catch {
    _ => fail("status was not UTF-8")
  }
  assert_true(off.contains("\"committed_revision\":null"))
}

///|
test "health JSON is deliberately minimal" {
  let sample = sample_observation()
  let healthy = evaluate_health(sample, 1500L, 5000L, 5000L)
  assert_eq(encode_health_live(healthy), b"{\"status\":\"live\"}")
  assert_eq(encode_health_ready(healthy), b"{\"status\":\"ready\"}")
  let stale = evaluate_health(sample, 7000L, 5000L, 5000L)
  assert_eq(encode_health_live(stale), b"{\"status\":\"unavailable\"}")
  assert_eq(encode_health_ready(stale), b"{\"status\":\"unavailable\"}")
}
