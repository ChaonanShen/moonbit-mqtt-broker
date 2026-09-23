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
