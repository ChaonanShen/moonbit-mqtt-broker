///|
pub(all) suberror ConfigFileError {
  ConfigFileError(String)
} derive(Eq, Debug)

///|
fn add_string(
  args : Array[String],
  option : String,
  value : @toml.TomlValue,
  key : String,
) -> Unit raise ConfigFileError {
  match value {
    TomlString(text) => {
      args.push(option)
      args.push(text)
    }
    _ => raise ConfigFileError(key + " must be a string")
  }
}

///|
fn add_integer(
  args : Array[String],
  option : String,
  value : @toml.TomlValue,
  key : String,
) -> Unit raise ConfigFileError {
  match value {
    TomlInteger(number) => {
      args.push(option)
      args.push(number.to_string())
    }
    _ => raise ConfigFileError(key + " must be an integer")
  }
}

///|
fn add_boolean(
  args : Array[String],
  option : String,
  value : @toml.TomlValue,
  key : String,
) -> Unit raise ConfigFileError {
  match value {
    TomlBoolean(flag) => {
      args.push(option)
      args.push(if flag { "true" } else { "false" })
    }
    _ => raise ConfigFileError(key + " must be a boolean")
  }
}

///|
fn map_section(
  args : Array[String],
  section_name : String,
  value : @toml.TomlValue,
) -> Unit raise ConfigFileError {
  let table = match value {
    TomlTable(value) => value
    _ => raise ConfigFileError(section_name + " must be a table")
  }
  for key, entry in table {
    let full_key = section_name + "." + key
    match full_key {
      "server.listen" => add_string(args, "--listen", entry, full_key)
      "server.max_connections" =>
        add_integer(args, "--max-connections", entry, full_key)
      "server.max_packet_size" =>
        add_integer(args, "--max-packet-size", entry, full_key)
      "server.max_receive_buffer_size" =>
        add_integer(args, "--max-receive-buffer-size", entry, full_key)
      "server.max_outbound_queue" =>
        add_integer(args, "--max-outbound-queue", entry, full_key)
      "server.max_runtime_events" =>
        add_integer(args, "--max-runtime-events", entry, full_key)
      "server.connect_timeout_ms" =>
        add_integer(args, "--connect-timeout-ms", entry, full_key)
      "server.keep_alive_check_interval_ms" =>
        add_integer(args, "--keep-alive-check-interval-ms", entry, full_key)
      "broker.max_subscriptions_per_session" =>
        add_integer(args, "--max-subscriptions-per-session", entry, full_key)
      "broker.max_subscriptions_total" =>
        add_integer(args, "--max-subscriptions-total", entry, full_key)
      "broker.max_retained_messages" =>
        add_integer(args, "--max-retained-messages", entry, full_key)
      "broker.max_sessions" =>
        add_integer(args, "--max-sessions", entry, full_key)
      "broker.max_inflight_per_session" =>
        add_integer(args, "--max-inflight-per-session", entry, full_key)
      "broker.max_inflight_total" =>
        add_integer(args, "--max-inflight-total", entry, full_key)
      "broker.max_pending_qos1_per_session" =>
        add_integer(args, "--max-pending-qos1-per-session", entry, full_key)
      "broker.max_pending_qos1_total" =>
        add_integer(args, "--max-pending-qos1-total", entry, full_key)
      "broker.persistent_session_expiry" =>
        add_string(args, "--persistent-session-expiry", entry, full_key)
      "broker.max_session_expirations_per_tick" =>
        add_integer(args, "--max-session-expirations-per-tick", entry, full_key)
      "persistence.data_dir" => add_string(args, "--data-dir", entry, full_key)
      "persistence.max_snapshot_bytes" =>
        add_integer(args, "--max-snapshot-bytes", entry, full_key)
      "persistence.snapshot_debounce_ms" =>
        add_integer(args, "--snapshot-debounce-ms", entry, full_key)
      "persistence.snapshot_max_delay_ms" =>
        add_integer(args, "--snapshot-max-delay-ms", entry, full_key)
      "persistence.snapshot_retry_ms" =>
        add_integer(args, "--snapshot-retry-ms", entry, full_key)
      "tls.cert" => add_string(args, "--tls-cert", entry, full_key)
      "tls.key" => add_string(args, "--tls-key", entry, full_key)
      "tls.handshake_timeout_ms" =>
        add_integer(args, "--tls-handshake-timeout-ms", entry, full_key)
      "security.allow_anonymous" =>
        add_boolean(args, "--allow-anonymous", entry, full_key)
      "security.password_file" =>
        add_string(args, "--password-file", entry, full_key)
      "security.acl_file" => add_string(args, "--acl-file", entry, full_key)
      "observability.system_metrics_interval_ms" =>
        add_integer(args, "--system-metrics-interval-ms", entry, full_key)
      "observability.log_format" =>
        add_string(args, "--log-format", entry, full_key)
      "observability.log_level" =>
        add_string(args, "--log-level", entry, full_key)
      _ => raise ConfigFileError("unknown configuration key: " + full_key)
    }
  }
}

///|
/// Parses a complete TOML document with the maintained bobzhang/toml parser
/// and returns deterministic CLI-equivalent arguments for precedence merging.
pub fn parse_config_file(
  contents : String,
) -> Array[String] raise ConfigFileError {
  let document = @toml.parse(contents) catch {
    _ => raise ConfigFileError("invalid TOML configuration")
  }
  if !document.validate() {
    raise ConfigFileError("invalid TOML configuration")
  }
  let root = match document {
    TomlTable(value) => value
    _ => raise ConfigFileError("configuration root must be a table")
  }
  let args : Array[String] = []
  let sections = [
    "server", "broker", "persistence", "tls", "security", "observability",
  ]
  for section in sections {
    match root.get(section) {
      Some(value) => map_section(args, section, value)
      None => ()
    }
  }
  for key, _ in root {
    if !sections.contains(key) {
      raise ConfigFileError("unknown configuration section: " + key)
    }
  }
  args
}
