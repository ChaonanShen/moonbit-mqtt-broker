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

///|
test "observation cache retains old generation after rejected replacement" {
  let config = ManagementConfig::new(enabled=true, token_file="/tmp/tokens").unwrap()
  let ledger = @budget.Ledger::new(config.required_bytes() + 1024L, 0L).unwrap()
  let budget = ManagementBudget::new(config, ledger).unwrap()
  let cache = ObservationCache::new(budget).unwrap()
  let first = sample_observation()
  assert_true(cache.publish(first, metrics_body=b"metric 1\n"))
  assert_eq(cache.captured_at(), Some(1000L))
  let old_metrics = cache.metrics_body(1500L).unwrap()
  assert_eq(old_metrics, b"metric 1\n")
  let oversized = {
    ..first,
    boot_id: "x".repeat(70000),
    captured_monotonic_ms: 2000L,
  }
  assert_false(cache.publish(oversized, metrics_body=b"metric 2\n"))
  assert_false(
    cache.publish(first, metrics_body=Bytes::from_array(Array::make(65537, 65))),
  )
  assert_false(cache.publish({ ..first, captured_monotonic_ms: 999L }))
  assert_false(cache.publish({ ..first, boot_id: "different-boot" }))
  assert_false(cache.publish({ ..first, driver_progress_monotonic_ms: 2000L }))

  assert_eq(cache.captured_at(), Some(1000L))
  assert_eq(cache.metrics_body(1500L), Ok(b"metric 1\n"))
  assert_true(
    cache.publish(
      { ..first, captured_monotonic_ms: 1700L },
      metrics_body=b"metric 3\n",
    ),
  )
  assert_eq(old_metrics, b"metric 1\n")
  assert_eq(cache.metrics_body(1800L), Ok(b"metric 3\n"))
  cache.close()
  assert_true(budget.close())
  assert_eq(ledger.occupied(), 0L)
}

///|
test "cache age and driver heartbeat control status separately" {
  let config = ManagementConfig::new(enabled=true, token_file="/tmp/tokens").unwrap()
  let ledger = @budget.Ledger::new(config.required_bytes() + 1024L, 0L).unwrap()
  let budget = ManagementBudget::new(config, ledger).unwrap()
  let cache = ObservationCache::new(budget).unwrap()
  assert_true(cache.publish(sample_observation()))
  let fresh_body = @utf8.decode(cache.status_body(1500L).unwrap()) catch {
    _ => fail("cached status was not UTF-8")
  }
  assert_true(fresh_body.contains("\"observation_age_ms\":\"500\""))
  assert_true(cache.metrics_body(1500L) is Err(Unavailable))
  let rendered = @utf8.decode(
    cache.render_metrics(1500L, ManagementRejections::new()).unwrap(),
  ) catch {
    _ => fail("metrics were not UTF-8")
  }
  assert_true(
    rendered.contains("moonbit_mqtt_broker_observation_age_seconds 0.500"),
  )
  cache.update_driver_progress(6500L)
  assert_true(cache.status_body(7000L) is Err(Stale))
  assert_true(cache.health(7000L).unwrap().live)
  let fresh = {
    ..sample_observation(),
    captured_monotonic_ms: 7000L,
    driver_progress_monotonic_ms: 6500L,
  }
  assert_true(cache.publish(fresh))
  assert_true(cache.status_body(7500L) is Ok(_))
  assert_true(cache.status_body(12000L) is Err(Stale))
  assert_false(cache.health(12000L).unwrap().live)
  cache.close()
  assert_true(budget.close())
}

///|
test "cache owner prevents an early parent release while a writer holds a slot" {
  let config = ManagementConfig::new(enabled=true, token_file="/tmp/tokens").unwrap()
  let ledger = @budget.Ledger::new(config.required_bytes() + 1024L, 0L).unwrap()
  let budget = ManagementBudget::new(config, ledger).unwrap()
  let cache = ObservationCache::new(budget).unwrap()
  let writer = budget.acquire().unwrap()
  assert_false(budget.close())
  assert_eq(ledger.committed(), config.required_bytes())
  cache.close()
  assert_false(budget.is_closed())
  assert_true(writer.release())
  assert_true(budget.is_closed())
  assert_eq(ledger.live_tickets(), 0)
}

///|
test "Prometheus text has fixed metrics, units and nonzero ages" {
  let sample = {
    ..sample_observation(),
    messages_sent: 9223372036854775807L,
    resources: [
      {
        name: "auth_request",
        committed_bytes: 5L,
        reserved_bytes: 2L,
        limit_bytes: 100L,
      },
    ],
    persistence_state: Healthy,
  }
  let rejected = ManagementRejections::new()
  rejected.record(RejectedAuth)
  let value = @utf8.decode(
    render_prometheus(sample, 2500L, 2000L, rejected).unwrap(),
  ) catch {
    _ => fail("metrics were not UTF-8")
  }
  assert_true(
    value.has_prefix(
      "# HELP moonbit_mqtt_broker_build_info Broker build information\n",
    ),
  )
  assert_true(
    value.contains(
      "moonbit_mqtt_broker_publish_actions_total 9223372036854775807",
    ),
  )
  assert_true(
    value.contains(
      "moonbit_mqtt_broker_resource_committed_bytes{resource=\"auth_request\"} 5",
    ),
  )
  assert_true(
    value.contains("moonbit_mqtt_broker_snapshot_state{state=\"healthy\"} 1"),
  )
  assert_true(
    value.contains(
      "moonbit_mqtt_broker_management_rejected_total{reason=\"auth\"} 1",
    ),
  )
  assert_true(
    value.contains("moonbit_mqtt_broker_observation_age_seconds 1.500"),
  )
  assert_true(
    value.contains("moonbit_mqtt_broker_driver_progress_age_seconds 0.500"),
  )
  assert_true(value.has_suffix("\n"))
  let mut series = 0
  for line in value.split("\n") {
    if line.has_prefix("moonbit_mqtt_broker_") {
      series += 1
    }
  }
  assert_true(series <= 256)
  assert_false(value.contains("fixture-boot"))
  assert_false(value.contains("client_id"))
  assert_false(value.contains("topic="))
}

///|
test "Prometheus build label escapes quote, backslash and newline" {
  let weird = "v" + "\"" + "\\" + "\n"
  let sample = { ..sample_observation(), version: weird }
  let output = @utf8.decode(
    render_prometheus(sample, 2000L, 1000L, ManagementRejections::new()).unwrap(),
  ) catch {
    _ => fail("metrics were not UTF-8")
  }
  let expected = @utf8.decode(
    Bytes::from_array([
      118, 101, 114, 115, 105, 111, 110, 61, 34, 118, 92, 34, 92, 92, 92, 110, 34,
      44, 116, 97, 114, 103, 101, 116, 61, 34, 110, 97, 116, 105, 118, 101, 34,
    ]),
  ) catch {
    _ => fail("expected ASCII was invalid")
  }
  assert_true(output.contains(expected))
}

///|
test "Prometheus rejects untrusted categories, duplicates and bad clocks" {
  let reject = ManagementRejections::new()
  let fake = {
    ..sample_observation(),
    resources: [
      {
        name: "client_123",
        committed_bytes: 1L,
        reserved_bytes: 0L,
        limit_bytes: 2L,
      },
    ],
  }
  assert_true(
    render_prometheus(fake, 2000L, 1000L, reject) is Err(InvalidResource),
  )
  let duplicate = {
    ..sample_observation(),
    resources: [
      {
        name: "auth_request",
        committed_bytes: 1L,
        reserved_bytes: 0L,
        limit_bytes: 2L,
      },
      {
        name: "auth_request",
        committed_bytes: 2L,
        reserved_bytes: 0L,
        limit_bytes: 2L,
      },
    ],
  }
  assert_true(
    render_prometheus(duplicate, 2000L, 1000L, reject) is Err(InvalidResource),
  )
  assert_true(
    render_prometheus(sample_observation(), 900L, 900L, reject)
    is Err(InvalidClock),
  )
}

///|
test "shutdown withdraws ready before releasing cache ownership" {
  let config = ManagementConfig::new(enabled=true, token_file="/tmp/tokens").unwrap()
  let ledger = @budget.Ledger::new(config.required_bytes() + 1024L, 0L).unwrap()
  let budget = ManagementBudget::new(config, ledger).unwrap()
  let cache = ObservationCache::new(budget).unwrap()
  let sample = sample_observation()
  assert_true(cache.publish(sample))
  cache.mark_stopping()
  let health = cache.health(1200L).unwrap()
  assert_true(health.live)
  assert_false(health.ready)
  assert_true(health.reasons.contains("stopping"))
  assert_true(cache.status_body(1200L) is Err(Stale))
  assert_false(cache.publish({ ..sample, captured_monotonic_ms: 1300L }))
  cache.close()
  assert_true(budget.close())
}
