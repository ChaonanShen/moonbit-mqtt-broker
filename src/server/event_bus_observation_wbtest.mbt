///|
fn observation_bus_fixture() -> (EventBus, @router.BrokerState) {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  let data : @async.Queue[DriverEvent] = @async.Queue(kind=Blocking(32))
  let bus = EventBus::new(config, state.resource_ledger(), data).unwrap()
  (bus, state)
}

///|
async test "observation due survives continuous higher-priority control" {
  let (bus, state) = observation_bus_fixture()
  bus.post_observation()
  for index in 0..<16 {
    bus.post_tick(CheckDeadlines(index.to_int64()))
    bus.post_observation()
    assert_true(bus.next() is Some(Runtime(CheckDeadlines(_))))
  }
  assert_true(bus.next() is Some(ObservationDue))
  assert_false(bus.observation_due)
  assert_eq(bus.observation_wait_events, 0)
  bus.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
async test "observation bound preserves the owed MQTT data opportunity" {
  let (bus, state) = observation_bus_fixture()
  bus.post_observation()
  assert_true(bus.data.try_put(Runtime(CheckDeadlines(999L))))
  for index in 0..<8 {
    bus.post_tick(AuthenticationPollDue(index.to_int64()))
    assert_true(bus.next() is Some(Runtime(AuthenticationPollDue(_))))
  }
  assert_true(bus.next() is Some(Runtime(CheckDeadlines(999L))))
  for index in 0..<7 {
    bus.post_tick(AuthenticationPollDue((index + 100).to_int64()))
    assert_true(bus.next() is Some(Runtime(AuthenticationPollDue(_))))
  }
  assert_true(bus.next() is Some(ObservationDue))
  bus.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
async test "observation notifications coalesce and close clears pending state" {
  let (bus, state) = observation_bus_fixture()
  for _ in 0..<1000 {
    bus.post_observation()
  }
  assert_true(bus.observation_due)
  assert_true(bus.next() is Some(ObservationDue))
  assert_false(bus.observation_due)
  bus.post_observation()
  bus.close()
  assert_false(bus.observation_due)
  assert_eq(state.managed_bytes(), 0L)
}
