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
