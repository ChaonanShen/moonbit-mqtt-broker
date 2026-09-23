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

///|
test "all B management TOML fields map to CLI options" {
  let args = parse_config_file(
    (
      #|[management]
      #|details_enabled = true
      #|operations_enabled = true
      #|query_queue_limit = 4
      #|operation_queue_limit = 5
      #|max_operation_records = 20
      #|max_running_operations = 3
      #|operation_timeout_ms = 45000
      #|operation_retention_ms = 120000
      #|max_cursor_records = 32
      #|cursor_ttl_ms = 12000
      #|default_page_size = 10
      #|max_page_size = 20
      #|query_scan_limit = 64
      #|query_timeout_ms = 1500
      #|max_audit_records = 128
      #|command_rate = 7
      #|command_burst = 14
      #|max_index_bytes = 4194304
      #|
    ),
  )
  assert_eq(args, [
    "--management-details-enabled", "true", "--management-operations-enabled", "true",
    "--management-query-queue-limit", "4", "--management-operation-queue-limit",
    "5", "--management-max-operation-records", "20", "--management-max-running-operations",
    "3", "--management-operation-timeout-ms", "45000", "--management-operation-retention-ms",
    "120000", "--management-max-cursor-records", "32", "--management-cursor-ttl-ms",
    "12000", "--management-default-page-size", "10", "--management-max-page-size",
    "20", "--management-query-scan-limit", "64", "--management-query-timeout-ms",
    "1500", "--management-max-audit-records", "128", "--management-command-rate",
    "7", "--management-command-burst", "14", "--management-max-index-bytes", "4194304",
  ])
}

///|
test "listener array keeps stable identities and rejects missing fields" {
  assert_eq(
    parse_config_file(
      "[[listeners]]\nid = \"plain\"\ntransport = \"tcp\"\nlisten = \"127.0.0.1:1883\"\n[[listeners]]\nid = \"secure\"\ntransport = \"tls\"\nlisten = \"127.0.0.1:8883\"\nmax_connections = 4\ntls_cert = \"/tmp/cert\"\ntls_key = \"/tmp/key\"\n",
    ),
    [
      "--listener-id", "plain", "--listener-transport", "tcp", "--listener-listen",
      "127.0.0.1:1883", "--listener-id", "secure", "--listener-transport", "tls",
      "--listener-listen", "127.0.0.1:8883", "--listener-max-connections", "4", "--listener-tls-cert",
      "/tmp/cert", "--listener-tls-key", "/tmp/key",
    ],
  )
  assert_true(
    config_rejected("[[listeners]]\nid = \"missing\"\ntransport = \"tcp\"\n"),
  )
  assert_true(
    config_rejected(
      "[[listeners]]\nid = \"x\"\ntransport = \"tcp\"\nlisten = \"127.0.0.1:1\"\nunknown = 1\n",
    ),
  )
}

///|
test "WS listener arrays keep origin entries without flattening identity" {
  let args = parse_config_file(
    "[[listeners]]\nid = \"browser\"\ntransport = \"wss\"\nlisten = \"0.0.0.0:8084\"\ntls_cert = \"/cert\"\ntls_key = \"/key\"\nws_path = \"/mqtt\"\nws_allowed_origins = [\"https://one.example\", \"https://two.example\"]\nws_require_origin = true\n",
  )
  assert_true(args.contains("--listener-ws-path"))
  assert_true(args.contains("--listener-ws-require-origin"))
  assert_eq(
    args.filter(value => value == "--listener-ws-allowed-origin").length(),
    2,
  )
  assert_true(
    config_rejected(
      "[[listeners]]\nid = \"browser\"\ntransport = \"ws\"\nlisten = \"127.0.0.1:8083\"\nws_allowed_origins = [1]\n",
    ),
  )
}
