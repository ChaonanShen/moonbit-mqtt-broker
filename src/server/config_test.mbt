///|
fn broker_config() -> @router.BrokerConfig {
  @router.BrokerConfig::new(2, 4, 3).unwrap()
}

///|
test "server config accepts exact lower bounds" {
  let config = ServerConfig::new(1, 2, 2, 1, 1, 1, 1, broker_config()).unwrap()
  assert_eq(config.max_connections(), 1)
  assert_eq(config.max_packet_size(), 2)
  assert_eq(config.max_receive_buffer_size(), 2)
}

///|
test "server config rejects every invalid resource boundary" {
  assert_true(ServerConfig::new(0, 2, 2, 1, 1, 1, 1, broker_config()) is Err(_))
  assert_true(ServerConfig::new(1, 1, 2, 1, 1, 1, 1, broker_config()) is Err(_))
  assert_true(ServerConfig::new(1, 3, 2, 1, 1, 1, 1, broker_config()) is Err(_))
  assert_true(ServerConfig::new(1, 2, 2, 0, 1, 1, 1, broker_config()) is Err(_))
  assert_true(ServerConfig::new(1, 2, 2, 1, 0, 1, 1, broker_config()) is Err(_))
  assert_true(ServerConfig::new(1, 2, 2, 1, 1, 0, 1, broker_config()) is Err(_))
  assert_true(ServerConfig::new(1, 2, 2, 1, 1, 5, 0, broker_config()) is Err(_))
  assert_true(ServerConfig::new(1, 2, 2, 1, 1, 5, 6, broker_config()) is Err(_))
}

///|
test "server default is the documented bounded configuration" {
  let config = ServerConfig::default()
  assert_eq(config.max_connections(), 128)
  assert_eq(config.max_packet_size(), 1048576)
  assert_eq(config.max_receive_buffer_size(), 1048576)
  assert_eq(config.max_outbound_queue(), 64)
  assert_eq(config.max_runtime_events(), 512)
  assert_eq(config.connect_timeout_ms(), 10000)
  assert_eq(config.keep_alive_check_interval_ms(), 100)
  assert_eq(config.auth_workers(), 1)
  assert_eq(config.auth_queue_limit(), 16)
  assert_eq(config.auth_timeout_ms(), 10000)
  assert_eq(config.auth_poll_interval_ms(), 5)
  assert_eq(config.auth_result_batch_limit(), 16)
  assert_eq(config.auth_shutdown_grace_ms(), 10000)
}

///|
test "connection ids are monotonic and never wrap" {
  let allocator = ConnectionIdAllocator::new()
  assert_eq(allocator.allocate().unwrap().value(), 1L)
  assert_eq(allocator.allocate().unwrap().value(), 2L)
  let exhausted = ConnectionIdAllocator::with_next(9223372036854775807L)
  assert_true(exhausted.allocate() is Err(ConnectionIdExhausted))
}

///|
test "server config validates authentication executor bounds" {
  let base = fn(
    workers : Int,
    queue : Int,
    timeout : Int,
    poll : Int,
    batch : Int,
    shutdown : Int,
  ) {
    ServerConfig::new(
      1,
      2,
      2,
      1,
      1,
      10,
      1,
      broker_config(),
      auth_workers=workers,
      auth_queue_limit=queue,
      auth_timeout_ms=timeout,
      auth_poll_interval_ms=poll,
      auth_result_batch_limit=batch,
      auth_shutdown_grace_ms=shutdown,
    )
  }
  assert_true(base(0, 0, 1, 1, 1, 1) is Err(_))
  assert_true(base(65, 0, 1, 1, 1, 1) is Err(_))
  assert_true(base(1, -1, 1, 1, 1, 1) is Err(_))
  assert_true(base(1, 4096, 1, 1, 1, 1) is Err(_))
  assert_true(base(1, 0, 0, 1, 1, 1) is Err(_))
  assert_true(base(1, 0, 1, 0, 1, 1) is Err(_))
  assert_true(base(1, 0, 1, 11, 1, 1) is Err(_))
  assert_true(base(1, 0, 1, 1, 0, 1) is Err(_))
  assert_true(base(1, 0, 1, 1, 2, 1) is Err(_))
  assert_true(base(1, 0, 1, 1, 1, 0) is Err(_))
  let config = base(2, 3, 7, 2, 4, 9).unwrap()
  assert_eq(config.auth_workers(), 2)
  assert_eq(config.auth_queue_limit(), 3)
  assert_eq(config.auth_timeout_ms(), 7)
  assert_eq(config.auth_poll_interval_ms(), 2)
  assert_eq(config.auth_result_batch_limit(), 4)
  assert_eq(config.auth_shutdown_grace_ms(), 9)
}
