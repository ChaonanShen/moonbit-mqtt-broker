///|
test "debounce collapses revisions and max delay forces commit" {
  let burst = SnapshotSchedule::new(0L, 250L, 2000L).unwrap()
  burst.observe(1L, 0L)
  burst.observe(2L, 100L)
  burst.observe(3L, 200L)
  assert_eq(burst.due_revision(449L), None)
  assert_eq(burst.due_revision(450L), Some(3L))
  burst.mark_submitted(3L)
  assert_eq(burst.due_revision(1000L), None)

  let continuous = SnapshotSchedule::new(0L, 250L, 2000L).unwrap()
  for revision in 1..<21 {
    continuous.observe(revision.to_int64(), (revision * 100 - 100).to_int64())
  }
  assert_eq(continuous.due_revision(1999L), None)
  assert_eq(continuous.due_revision(2000L), Some(20L))
}

///|
test "snapshot schedule ignores noise and force submits only dirty state" {
  let schedule = SnapshotSchedule::new(7L, 10L, 100L).unwrap()
  schedule.observe(7L, 10L)
  assert_eq(schedule.force_revision(), None)
  schedule.observe(8L, 20L)
  assert_eq(schedule.due_revision(29L), None)
  assert_eq(schedule.force_revision(), Some(8L))
  schedule.mark_submitted(8L)
  assert_eq(schedule.force_revision(), None)
}

///|
test "router driver snapshot polling is optional and nonblocking" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  let runtime = BrokerRuntime::new(config, state)
  let disabled = RouterDriver::new(runtime)
  assert_false(disabled.poll_snapshot(100L))
  assert_false(disabled.force_snapshot())

  let sink = @persistence.SnapshotSink::new()
  let snapshot_config = SnapshotDriverConfig::new(sink, 10L, 100L).unwrap()
  let enabled = RouterDriver::new(runtime, snapshot=snapshot_config)
  let client = @session.ClientId::new("scheduled").unwrap()
  ignore(
    state.apply(
      @router.BrokerEvent::CreateSessionWith({
        client_id: client,
        mode: @session.SessionMode::Persistent,
        attached: false,
      }),
    ),
  )
  assert_false(enabled.poll_snapshot(0L))
  assert_false(enabled.poll_snapshot(9L))
  assert_true(enabled.poll_snapshot(10L))
  assert_false(enabled.force_snapshot())
  sink.close()
}
