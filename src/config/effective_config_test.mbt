///|
test "hot config rebuilds defaults and keeps frozen CLI precedence" {
  let first = effective_hot_config(
    (
      #|[security]
      #|allow_anonymous = false
      #|password_file = "/bundle/old-passwords"
      #|acl_file = "/bundle/old-acl"
      #|[observability]
      #|log_level = "debug"
      #|system_metrics_interval_ms = 2000
      #|
    ),
    ["--password-file", "/cli/passwords", "--log-level", "warn"],
  )
  assert_eq(first.password_file, Some("/cli/passwords"))
  assert_eq(first.log_level, "warn")
  assert_eq(first.acl_file, Some("/bundle/old-acl"))
  assert_false(first.allow_anonymous)
  let second = effective_hot_config("[security]\nallow_anonymous = false\n", [
    "--password-file", "/cli/passwords", "--log-level", "warn",
  ])
  assert_eq(second.password_file, Some("/cli/passwords"))
  assert_eq(second.acl_file, None)
  assert_eq(second.log_level, "warn")
  assert_eq(second.system_metrics_interval_ms, 10000)
}

///|
test "hot config extracts named TLS roles after full TOML parse" {
  let effective = effective_hot_config(
    (
      #|[[listeners]]
      #|id = "plain"
      #|transport = "tcp"
      #|listen = "127.0.0.1:1883"
      #|[[listeners]]
      #|id = "browser"
      #|transport = "wss"
      #|listen = "127.0.0.1:8084"
      #|tls_cert = "/bundle/cert.pem"
      #|tls_key = "/bundle/key.pem"
      #|
    ),
    [],
  )
  assert_eq(effective.tls_sources, [
    {
      listener_id: "browser",
      cert_path: "/bundle/cert.pem",
      key_path: "/bundle/key.pem",
    },
  ])
}

///|
test "hot config rejects invalid effective safety settings" {
  let invalid = try {
    ignore(effective_hot_config("[security]\nallow_anonymous = false\n", []))
    false
  } catch {
    _ => true
  }
  assert_true(invalid)
  let stale = try {
    ignore(
      effective_hot_config(
        "[management]\nsnapshot_interval_ms = 3000\nsnapshot_max_age_ms = 5000\n",
        [],
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(stale)
}
