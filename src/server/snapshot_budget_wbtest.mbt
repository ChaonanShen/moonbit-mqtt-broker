///|
test "snapshot budget deferral leaves state dirty and does not allocate an export" {
  let resources = @budget.Limits::default()
    .with_value("max_snapshot_work_bytes", 0L)
    .unwrap()
  let config = @router.BrokerConfig::new(4, 8, 4, resources~).unwrap()
  let state = @router.BrokerState::new(config)
  let server = ServerConfig::new(2, 1024, 1024, 4, 4, 1000, 100, config).unwrap()
  let sink = @persistence.SnapshotSink::new()
  let driver = RouterDriver::new(
    BrokerRuntime::new(server, state),
    snapshot=SnapshotDriverConfig::new(sink, 1L, 1L).unwrap(),
  )
  ignore(
    state
    .apply(
      @router.CreateSessionWith({
        client_id: @session.ClientId::new("persistent").unwrap(),
        mode: @session.Persistent,
        attached: false,
      }),
    )
    .unwrap(),
  )
  let baseline = state.managed_bytes()
  assert_false(driver.poll_snapshot(0L))
  assert_false(driver.poll_snapshot(2L))
  assert_false(driver.force_snapshot())
  assert_eq(state.managed_bytes(), baseline)
  assert_true(driver.runtime.metrics.snapshot_budget_deferred >= 2L)
  assert_true(driver.snapshot.unwrap().schedule.force_revision() is Some(_))
  assert_eq(sink.committed_revision(), -1L)
  sink.discard()
}

///|
test "canonical usage counts include control frames exactly once" {
  let (bus, state, _) = bus_fixture()
  let sink = TransportSink::new(2)
  ignore(bus.register(ConnectionId::new(1L), sink).unwrap())
  assert_true(
    sink.enqueue_frame(b"hi", sink.reserve_frame(2L, true).unwrap(), None),
  )
  let mut sum = 0L
  for entry in state.resource_ledger().usage() {
    let (_, committed, reserved, _) = entry
    sum += committed + reserved
  }
  assert_eq(sum, state.resource_ledger().occupied())
  let json = resource_usage_json(state.resource_ledger())
  assert_true(json.contains("\"outbound\""))
  assert_false(json.contains("control_frame"))
  bus.close()
}
