///|
test "management observation reads fixed broker and ledger facts" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  let runtime = BrokerRuntime::new(config, state)
  let driver = RouterDriver::new(runtime)
  let now = @budget.monotonic_ms()
  let sample = driver.capture_observation(now, 12345L, {
    boot_id: "fixture-boot",
    boot_monotonic_ms: now,
    lifecycle: @management.ServiceLifecycle::Serving,
    mqtt_listener_up: true,
    management_listener_up: true,
    ready_require_snapshot_healthy: false,
  })
  assert_eq(sample.boot_id, "fixture-boot")
  assert_eq(sample.captured_unix_ms, 12345L)
  assert_eq(sample.sessions_total, 0L)
  assert_eq(sample.connections_registered, 0L)
  assert_eq(sample.connections_active, 0L)
  assert_eq(sample.messages_sent, 0L)
  assert_eq(
    sample.resource_total_committed,
    state.resource_ledger().committed(),
  )
  assert_eq(sample.resource_total_reserved, state.resource_ledger().reserved())
  assert_true(sample.resources.length() <= 32)
  assert_eq(sample.persistence_mode, @management.PersistenceMode::Off)
  assert_eq(sample.persistence_state, @management.PersistenceState::Disabled)
  assert_eq(sample.snapshot_committed_revision, None)
  let revision = state.snapshot_revision()
  ignore(
    driver.capture_observation(now, 12346L, {
      boot_id: "fixture-boot",
      boot_monotonic_ms: now,
      lifecycle: @management.ServiceLifecycle::Serving,
      mqtt_listener_up: true,
      management_listener_up: true,
      ready_require_snapshot_healthy: false,
    }),
  )
  assert_eq(state.snapshot_revision(), revision)
}
