///|
test "management defaults and fixed parent fee" {
  let config = ManagementConfig::default()
  assert_false(config.enabled())
  assert_eq(config.listen(), "127.0.0.1:9091")
  assert_eq(config.max_connections(), 16)
  assert_eq(config.max_header_bytes(), 4096)
  assert_eq(config.max_response_bytes(), 65536)
  assert_eq(config.required_bytes(), 5892096L)
}

///|
test "management rejects remote, ambiguous and invalid loopback binds" {
  for
    address in [
      "0.0.0.0:9091", "localhost:9091", "127.0.0.2:9091", "[::1]:9091", "127.0.0.1:0",
      "127.0.0.1:65536", "127.0.0.1:09091", "127.0.0.1:+9091", "127.0.0.1:9091/path",
    ] {
    assert_true(ManagementConfig::new(listen=address) is Err(_))
  }
  assert_true(ManagementConfig::new(listen="127.0.0.1:1") is Ok(_))
  assert_true(ManagementConfig::new(listen="127.0.0.1:65535") is Ok(_))
}

///|
test "management enforces time and body boundaries before enable" {
  assert_true(ManagementConfig::new(max_header_bytes=1023) is Err(_))
  assert_true(ManagementConfig::new(max_header_bytes=16385) is Err(_))
  assert_true(ManagementConfig::new(max_response_bytes=4095) is Err(_))
  assert_true(ManagementConfig::new(max_response_bytes=262145) is Err(_))
  assert_true(ManagementConfig::new(write_timeout_ms=5001) is Err(_))
  assert_true(
    ManagementConfig::new(snapshot_interval_ms=2000, snapshot_max_age_ms=5000)
    is Err(_),
  )
  assert_true(
    ManagementConfig::new(snapshot_interval_ms=100, snapshot_max_age_ms=300)
    is Ok(_),
  )
}

///|
test "management enabled needs a token source and adequate total fee" {
  assert_true(ManagementConfig::new(enabled=true) is Err(_))
  assert_true(
    ManagementConfig::new(
      enabled=true,
      token_file="/tmp/tokens",
      max_bytes_total=5892095L,
    )
    is Err(_),
  )
  assert_true(
    ManagementConfig::new(
      enabled=true,
      token_file="/tmp/tokens",
      max_bytes_total=5892096L,
    )
    is Ok(_),
  )
  // Disabled settings parse without reading or reserving a token file.
  assert_true(
    ManagementConfig::new(token_file="/missing", max_bytes_total=1L) is Ok(_),
  )
}

///|
test "management numeric option boundaries" {
  assert_true(ManagementConfig::new(max_connections=0) is Err(_))
  assert_true(ManagementConfig::new(max_connections=65) is Err(_))
  assert_true(ManagementConfig::new(max_header_bytes=1023) is Err(_))
  assert_true(ManagementConfig::new(max_header_bytes=16385) is Err(_))
  assert_true(ManagementConfig::new(max_header_count=0) is Err(_))
  assert_true(ManagementConfig::new(max_header_count=65) is Err(_))
  assert_true(ManagementConfig::new(max_response_bytes=4095) is Err(_))
  assert_true(ManagementConfig::new(max_response_bytes=262145) is Err(_))
  assert_true(ManagementConfig::new(request_timeout_ms=99) is Err(_))
  assert_true(ManagementConfig::new(request_timeout_ms=30001) is Err(_))
  assert_true(ManagementConfig::new(write_timeout_ms=99) is Err(_))
  assert_true(ManagementConfig::new(write_timeout_ms=30001) is Err(_))
  assert_true(ManagementConfig::new(snapshot_interval_ms=99) is Err(_))
  assert_true(ManagementConfig::new(snapshot_interval_ms=10001) is Err(_))
  assert_true(ManagementConfig::new(snapshot_max_age_ms=299) is Err(_))
  assert_true(ManagementConfig::new(snapshot_max_age_ms=60001) is Err(_))
  assert_true(ManagementConfig::new(request_rate=0) is Err(_))
  assert_true(ManagementConfig::new(request_rate=10001) is Err(_))
  assert_true(ManagementConfig::new(request_burst=0) is Err(_))
  assert_true(ManagementConfig::new(request_burst=20001) is Err(_))
  assert_true(ManagementConfig::new(connection_rate=0) is Err(_))
  assert_true(ManagementConfig::new(connection_rate=10001) is Err(_))
  assert_true(ManagementConfig::new(connection_burst=0) is Err(_))
  assert_true(ManagementConfig::new(connection_burst=20001) is Err(_))
  assert_true(ManagementConfig::new(max_connections=1) is Ok(_))
  assert_true(ManagementConfig::new(max_connections=64) is Ok(_))
  assert_true(ManagementConfig::new(max_header_bytes=1024) is Ok(_))
  assert_true(ManagementConfig::new(max_header_bytes=16384) is Ok(_))
  assert_true(ManagementConfig::new(max_header_count=1) is Ok(_))
  assert_true(ManagementConfig::new(max_header_count=64) is Ok(_))
  assert_true(ManagementConfig::new(max_response_bytes=4096) is Ok(_))
  assert_true(ManagementConfig::new(max_response_bytes=262144) is Ok(_))
  assert_true(
    ManagementConfig::new(request_timeout_ms=100, write_timeout_ms=100) is Ok(_),
  )
  assert_true(ManagementConfig::new(request_timeout_ms=30000) is Ok(_))
  assert_true(ManagementConfig::new(write_timeout_ms=100) is Ok(_))
  assert_true(
    ManagementConfig::new(write_timeout_ms=30000, request_timeout_ms=30000)
    is Ok(_),
  )
  assert_true(ManagementConfig::new(snapshot_interval_ms=100) is Ok(_))
  assert_true(
    ManagementConfig::new(snapshot_interval_ms=10000, snapshot_max_age_ms=30000)
    is Ok(_),
  )
  assert_true(
    ManagementConfig::new(snapshot_max_age_ms=300, snapshot_interval_ms=100)
    is Ok(_),
  )
  assert_true(ManagementConfig::new(snapshot_max_age_ms=60000) is Ok(_))
  assert_true(ManagementConfig::new(request_rate=1) is Ok(_))
  assert_true(ManagementConfig::new(request_rate=10000) is Ok(_))
  assert_true(ManagementConfig::new(request_burst=1) is Ok(_))
  assert_true(ManagementConfig::new(request_burst=20000) is Ok(_))
  assert_true(ManagementConfig::new(connection_rate=1) is Ok(_))
  assert_true(ManagementConfig::new(connection_rate=10000) is Ok(_))
  assert_true(ManagementConfig::new(connection_burst=1) is Ok(_))
  assert_true(ManagementConfig::new(connection_burst=20000) is Ok(_))
  assert_true(ManagementConfig::new(max_bytes_total=0L) is Err(_))
}
