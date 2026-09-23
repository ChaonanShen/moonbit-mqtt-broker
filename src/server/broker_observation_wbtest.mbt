///|
test "base observation reads fixed counters without publishing" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  let rt = BrokerRuntime::new(config, state)
  let revision = state.snapshot_revision()
  let empty = rt.collect_base_observation(2000L)
  assert_eq(empty.sessions_total, 0L)
  assert_eq(empty.connections_registered, 0L)
  assert_eq(empty.clients_connected, 0L)
  assert_eq(empty.resource_committed, state.resource_ledger().committed())
  assert_eq(empty.uptime_seconds, 2L)
  let id = ConnectionId::new(1L)
  ignore(
    rt.apply(TransportOpened({ connection_id: id, accepted_at_ms: 1000L })),
  )
  let opened = rt.collect_base_observation(3000L)
  assert_eq(opened.connections_registered, 1L)
  assert_eq(opened.clients_connected, 0L)
  assert_eq(state.snapshot_revision(), revision)
  assert_eq(rt.metrics().messages_sent(), 0L)
}
