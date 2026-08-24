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
