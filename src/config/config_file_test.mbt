///|
test "structured TOML maps to deterministic CLI arguments" {
  assert_eq(
    parse_config_file(
      (
        #|[server]
        #|listen = "0.0.0.0:1883"
        #|max_connections = 42
        #|[security]
        #|allow_anonymous = false
        #|password_file = "/run/secrets/passwords"
        #|[observability]
        #|log_format = "json"
        #|
      ),
    ),
    [
      "--listen", "0.0.0.0:1883", "--max-connections", "42", "--allow-anonymous",
      "false", "--password-file", "/run/secrets/passwords", "--log-format", "json",
    ],
  )
}

///|
fn config_rejected(contents : String) -> Bool {
  try {
    ignore(parse_config_file(contents))
    false
  } catch {
    _ => true
  }
}

///|
test "unknown sections keys and wrong types are fatal" {
  assert_true(config_rejected("[cluster]\nnodes = 3\n"))
  assert_true(config_rejected("[server]\nunknown = 3\n"))
  assert_true(config_rejected("[server]\nmax_connections = \"many\"\n"))
}

///|
test "duplicate TOML keys are rejected by the maintained parser" {
  assert_true(
    config_rejected("[server]\nmax_connections = 1\nmax_connections = 2\n"),
  )
}

///|
test "qos2 config exposes inbound and shared pending limits with alias conflicts" {
  let args = parse_config_file(
    "[broker]\nmax_pending_per_session = 2\nmax_pending_total = 3\nmax_inbound_qos2_per_session = 4\nmax_inbound_qos2_total = 5\n",
  )
  assert_true(args.contains("--max-pending-per-session"))
  assert_true(args.contains("--max-pending-total"))
  assert_true(args.contains("--max-inbound-qos2-per-session"))
  assert_true(args.contains("--max-inbound-qos2-total"))
  let rejected = try {
    ignore(
      parse_config_file(
        "[broker]\nmax_pending_total = 1\nmax_pending_qos1_total = 1\n",
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "authentication executor TOML maps to CLI bounds" {
  assert_eq(
    parse_config_file(
      "[security]\nauth_workers = 2\nauth_queue_limit = 7\nauth_timeout_ms = 9000\nauth_poll_interval_ms = 4\nauth_result_batch_limit = 6\nauth_shutdown_grace_ms = 8000\n",
    ),
    [
      "--auth-workers", "2", "--auth-queue-limit", "7", "--auth-timeout-ms", "9000",
      "--auth-poll-interval-ms", "4", "--auth-result-batch-limit", "6", "--auth-shutdown-grace-ms",
      "8000",
    ],
  )
  assert_true(config_rejected("[security]\nauth_workers = \"two\"\n"))
}

///|
test "all management TOML fields use the fixed CLI spellings" {
  let args = parse_config_file(
    (
      #|[management]
      #|enabled = false
      #|listen = "127.0.0.1:9191"
      #|token_file = "/missing/management.tokens"
      #|max_connections = 8
      #|max_header_bytes = 8192
      #|max_header_count = 16
      #|max_response_bytes = 32768
      #|request_timeout_ms = 9000
      #|write_timeout_ms = 3000
      #|snapshot_interval_ms = 2000
      #|snapshot_max_age_ms = 9000
      #|ready_require_snapshot_healthy = true
      #|request_rate = 40
      #|request_burst = 80
      #|connection_rate = 30
      #|connection_burst = 60
      #|max_bytes_total = 16777216
      #|
    ),
  )
  assert_eq(args, [
    "--management-enabled", "false", "--management-listen", "127.0.0.1:9191", "--management-token-file",
    "/missing/management.tokens", "--management-max-connections", "8", "--management-max-header-bytes",
    "8192", "--management-max-header-count", "16", "--management-max-response-bytes",
    "32768", "--management-request-timeout-ms", "9000", "--management-write-timeout-ms",
    "3000", "--management-snapshot-interval-ms", "2000", "--management-snapshot-max-age-ms",
    "9000", "--management-ready-require-snapshot-healthy", "true", "--management-request-rate",
    "40", "--management-request-burst", "80", "--management-connection-rate", "30",
    "--management-connection-burst", "60", "--management-max-bytes-total", "16777216",
  ])
}

///|
test "management TOML rejects wrong types, unknown keys, and duplicates" {
  assert_true(config_rejected("[management]\nenabled = 1\n"))
  assert_true(config_rejected("[management]\nmax_connections = \"many\"\n"))
  assert_true(config_rejected("[management]\ntoken_file = 42\n"))
  assert_true(config_rejected("[management]\nunknown = 1\n"))
  assert_true(
    config_rejected("[management]\nenabled = true\nenabled = false\n"),
  )
}
