///|
fn persistence_broker_config() -> @router.BrokerConfig {
  @router.BrokerConfig::new(
    4,
    16,
    8,
    max_sessions=8,
    max_inflight_per_session=4,
    max_inflight_total=16,
    max_pending_qos1_per_session=8,
    max_pending_qos1_total=32,
  ).unwrap()
}

///|
test "persistence config validates timing and size bounds" {
  let config = PersistenceConfig::new("data").unwrap()
  assert_eq(config.data_dir(), "data")
  assert_eq(config.max_snapshot_bytes(), 67108864L)
  assert_eq(config.debounce_ms(), 250L)
  assert_eq(config.max_delay_ms(), 2000L)
  assert_eq(config.retry_ms(), 1000L)
  assert_true(PersistenceConfig::new("") is Err(_))
  assert_true(PersistenceConfig::new("data", max_snapshot_bytes=23L) is Err(_))
  assert_true(PersistenceConfig::new("data", debounce_ms=0L) is Err(_))
  assert_true(
    PersistenceConfig::new("data", debounce_ms=20L, max_delay_ms=19L) is Err(_),
  )
  assert_true(PersistenceConfig::new("data", retry_ms=0L) is Err(_))
}

///|
test "snapshot decode limits reject unsafe inputs" {
  let broker = persistence_broker_config()
  assert_true(SnapshotDecodeLimits::new(broker, -1) is Err(_))
  assert_true(
    SnapshotDecodeLimits::new(broker, 1, max_snapshot_bytes=23) is Err(_),
  )
  let limits = SnapshotDecodeLimits::new(broker, 1024, max_snapshot_bytes=4096).unwrap()
  assert_eq(limits.broker_config(), broker)
  assert_eq(limits.max_message_payload_bytes(), 1024)
  assert_eq(limits.max_snapshot_bytes(), 4096)
}
