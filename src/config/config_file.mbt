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
  if section_name == "broker" {
    for suffix in ["per_session", "total"] {
      if table.get("max_pending_" + suffix) is Some(_) &&
        table.get("max_pending_qos1_" + suffix) is Some(_) {
        raise ConfigFileError("conflicting pending limit aliases: " + suffix)
      }
    }
  }
  for key, entry in table {
    let full_key = section_name + "." + key
    match full_key {
      "management.enabled" =>
        add_boolean(args, "--management-enabled", entry, full_key)
      "management.listen" =>
        add_string(args, "--management-listen", entry, full_key)
      "management.token_file" =>
        add_string(args, "--management-token-file", entry, full_key)
      "management.max_connections" =>
        add_integer(args, "--management-max-connections", entry, full_key)
      "management.max_header_bytes" =>
        add_integer(args, "--management-max-header-bytes", entry, full_key)
      "management.max_header_count" =>
        add_integer(args, "--management-max-header-count", entry, full_key)
      "management.max_response_bytes" =>
        add_integer(args, "--management-max-response-bytes", entry, full_key)
      "management.request_timeout_ms" =>
        add_integer(args, "--management-request-timeout-ms", entry, full_key)
      "management.write_timeout_ms" =>
        add_integer(args, "--management-write-timeout-ms", entry, full_key)
      "management.snapshot_interval_ms" =>
        add_integer(args, "--management-snapshot-interval-ms", entry, full_key)
      "management.snapshot_max_age_ms" =>
        add_integer(args, "--management-snapshot-max-age-ms", entry, full_key)
      "management.ready_require_snapshot_healthy" =>
        add_boolean(
          args, "--management-ready-require-snapshot-healthy", entry, full_key,
        )
      "management.request_rate" =>
        add_integer(args, "--management-request-rate", entry, full_key)
      "management.request_burst" =>
        add_integer(args, "--management-request-burst", entry, full_key)
      "management.connection_rate" =>
        add_integer(args, "--management-connection-rate", entry, full_key)
      "management.connection_burst" =>
        add_integer(args, "--management-connection-burst", entry, full_key)
      "management.details_enabled" =>
        add_boolean(args, "--management-details-enabled", entry, full_key)
      "management.operations_enabled" =>
        add_boolean(args, "--management-operations-enabled", entry, full_key)
      "management.query_queue_limit" =>
        add_integer(args, "--management-query-queue-limit", entry, full_key)
      "management.operation_queue_limit" =>
        add_integer(args, "--management-operation-queue-limit", entry, full_key)
      "management.max_operation_records" =>
        add_integer(args, "--management-max-operation-records", entry, full_key)
      "management.max_running_operations" =>
        add_integer(
          args, "--management-max-running-operations", entry, full_key,
        )
      "management.operation_timeout_ms" =>
        add_integer(args, "--management-operation-timeout-ms", entry, full_key)
      "management.operation_retention_ms" =>
        add_integer(
          args, "--management-operation-retention-ms", entry, full_key,
        )
      "management.max_cursor_records" =>
        add_integer(args, "--management-max-cursor-records", entry, full_key)
      "management.cursor_ttl_ms" =>
        add_integer(args, "--management-cursor-ttl-ms", entry, full_key)
      "management.default_page_size" =>
        add_integer(args, "--management-default-page-size", entry, full_key)
      "management.max_page_size" =>
        add_integer(args, "--management-max-page-size", entry, full_key)
      "management.query_scan_limit" =>
        add_integer(args, "--management-query-scan-limit", entry, full_key)
      "management.query_timeout_ms" =>
        add_integer(args, "--management-query-timeout-ms", entry, full_key)
      "management.max_audit_records" =>
        add_integer(args, "--management-max-audit-records", entry, full_key)
      "management.command_rate" =>
        add_integer(args, "--management-command-rate", entry, full_key)
      "management.command_burst" =>
        add_integer(args, "--management-command-burst", entry, full_key)
      "management.max_index_bytes" =>
        add_integer(args, "--management-max-index-bytes", entry, full_key)
      "management.max_bytes_total" =>
        add_integer(args, "--management-max-bytes-total", entry, full_key)
      "limits.enabled" =>
        add_boolean(args, "--rate-limits-enabled", entry, full_key)
      "limits.per_ip_enabled" =>
        add_boolean(args, "--per-ip-limits-enabled", entry, full_key)
      "protocol.mqtt5_enabled" =>
        add_boolean(args, "--mqtt5-enabled", entry, full_key)
      "protocol.server_receive_maximum" =>
        add_integer(args, "--mqtt5-server-receive-maximum", entry, full_key)
      "protocol.server_keep_alive" =>
        add_integer(args, "--mqtt5-server-keep-alive", entry, full_key)
      "protocol.topic_alias_maximum" =>
        add_integer(args, "--mqtt5-topic-alias-maximum", entry, full_key)
      "protocol.max_property_bytes" =>
        add_integer(args, "--mqtt5-max-property-bytes", entry, full_key)
      "protocol.max_user_properties" =>
        add_integer(args, "--mqtt5-max-user-properties", entry, full_key)
      "protocol.max_subscription_entries" =>
        add_integer(args, "--mqtt5-max-subscription-entries", entry, full_key)
      "protocol.max_alias_bytes_per_connection" =>
        add_integer(
          args, "--mqtt5-max-alias-bytes-per-connection", entry, full_key,
        )
      "protocol.max_delayed_wills" =>
        add_integer(args, "--mqtt5-max-delayed-wills", entry, full_key)
      "protocol.max_expiry_work_per_turn" =>
        add_integer(args, "--mqtt5-max-expiry-work-per-turn", entry, full_key)
      "protocol.write_timeout_ms" =>
        add_integer(args, "--mqtt5-write-timeout-ms", entry, full_key)
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
      "broker.max_pending_per_session" =>
        add_integer(args, "--max-pending-per-session", entry, full_key)
      "broker.max_pending_total" =>
        add_integer(args, "--max-pending-total", entry, full_key)
      "broker.max_inbound_qos2_per_session" =>
        add_integer(args, "--max-inbound-qos2-per-session", entry, full_key)
      "broker.max_inbound_qos2_total" =>
        add_integer(args, "--max-inbound-qos2-total", entry, full_key)
      "broker.persistent_session_expiry" =>
        add_string(args, "--persistent-session-expiry", entry, full_key)
      "broker.max_session_expirations_per_tick" =>
        add_integer(args, "--max-session-expirations-per-tick", entry, full_key)
      "persistence.data_dir" => add_string(args, "--data-dir", entry, full_key)
      "persistence.mode" =>
        add_string(args, "--persistence-mode", entry, full_key)
      "persistence.wal_disk_max_bytes" =>
        add_integer(args, "--wal-disk-max-bytes", entry, full_key)
      "persistence.wal_disk_reserve_bytes" =>
        add_integer(args, "--wal-disk-reserve-bytes", entry, full_key)
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
      "security.auth_workers" =>
        add_integer(args, "--auth-workers", entry, full_key)
      "security.auth_queue_limit" =>
        add_integer(args, "--auth-queue-limit", entry, full_key)
      "security.auth_timeout_ms" =>
        add_integer(args, "--auth-timeout-ms", entry, full_key)
      "security.auth_poll_interval_ms" =>
        add_integer(args, "--auth-poll-interval-ms", entry, full_key)
      "security.auth_result_batch_limit" =>
        add_integer(args, "--auth-result-batch-limit", entry, full_key)
      "security.auth_shutdown_grace_ms" =>
        add_integer(args, "--auth-shutdown-grace-ms", entry, full_key)
      "observability.system_metrics_interval_ms" =>
        add_integer(args, "--system-metrics-interval-ms", entry, full_key)
      "observability.log_format" =>
        add_string(args, "--log-format", entry, full_key)
      "observability.log_level" =>
        add_string(args, "--log-level", entry, full_key)
      "reload.enabled" => add_boolean(args, "--reload-enabled", entry, full_key)
      "reload.manifest_file" =>
        add_string(args, "--reload-manifest-file", entry, full_key)
      "reload.material_runtime_dir" =>
        add_string(args, "--reload-material-runtime-dir", entry, full_key)
      "reload.prepare_timeout_ms" =>
        add_integer(args, "--reload-prepare-timeout-ms", entry, full_key)
      "reload.max_source_bytes" =>
        add_integer(args, "--reload-max-source-bytes", entry, full_key)
      "reload.max_generation_bytes" =>
        add_integer(args, "--reload-max-generation-bytes", entry, full_key)
      "reload.max_reconcile_items_per_turn" =>
        add_integer(
          args, "--reload-max-reconcile-items-per-turn", entry, full_key,
        )
      "reload.max_reconcile_bytes_per_turn" =>
        add_integer(
          args, "--reload-max-reconcile-bytes-per-turn", entry, full_key,
        )
      "reload.max_accounts" =>
        add_integer(args, "--reload-max-accounts", entry, full_key)
      "reload.max_acl_rules" =>
        add_integer(args, "--reload-max-acl-rules", entry, full_key)
      _ => {
        let specs = @budget.byte_limit_specs()
        specs.append(@budget.rate_limit_specs())
        let mut found = false
        for spec in specs {
          let (section, name, _) = spec
          if section == section_name && name == key {
            add_integer(
              args,
              "--" + key.replace_all(old="_", new="-"),
              entry,
              full_key,
            )
            found = true
            break
          }
        }
        if !found {
          raise ConfigFileError("unknown configuration key: " + full_key)
        }
      }
    }
  }
}

///|
fn map_listeners(
  args : Array[String],
  value : @toml.TomlValue,
) -> Unit raise ConfigFileError {
  let entries = match value {
    TomlArray(entries) => entries
    _ => raise ConfigFileError("listeners must be an array of tables")
  }
  if entries.length() < 1 || entries.length() > 16 {
    raise ConfigFileError("listeners count must be in 1..16")
  }
  for entry in entries {
    let table = match entry {
      TomlTable(table) => table
      _ => raise ConfigFileError("listeners entries must be tables")
    }
    for required in ["id", "transport", "listen"] {
      if table.get(required) is None {
        raise ConfigFileError("listeners." + required + " is required")
      }
    }
    for key, _ in table {
      if ![
          "id", "transport", "listen", "max_connections", "tls_cert", "tls_key",
          "tls_handshake_timeout_ms", "ws_path", "ws_allowed_origins", "ws_require_origin",
          "http_upgrade_timeout_ms", "max_http_header_bytes", "max_ws_frame_bytes",
          "max_ws_message_bytes",
        ].contains(key) {
        raise ConfigFileError("unknown listener key: " + key)
      }
    }
    add_string(args, "--listener-id", table.get("id").unwrap(), "listeners.id")
    add_string(
      args,
      "--listener-transport",
      table.get("transport").unwrap(),
      "listeners.transport",
    )
    add_string(
      args,
      "--listener-listen",
      table.get("listen").unwrap(),
      "listeners.listen",
    )
    if table.get("max_connections") is Some(value) {
      add_integer(
        args, "--listener-max-connections", value, "listeners.max_connections",
      )
    }
    if table.get("tls_cert") is Some(value) {
      add_string(args, "--listener-tls-cert", value, "listeners.tls_cert")
    }
    if table.get("tls_key") is Some(value) {
      add_string(args, "--listener-tls-key", value, "listeners.tls_key")
    }
    if table.get("tls_handshake_timeout_ms") is Some(value) {
      add_integer(
        args, "--listener-tls-handshake-timeout-ms", value, "listeners.tls_handshake_timeout_ms",
      )
    }
    if table.get("ws_path") is Some(value) {
      add_string(args, "--listener-ws-path", value, "listeners.ws_path")
    }
    if table.get("ws_allowed_origins") is Some(value) {
      let origins = match value {
        TomlArray(origins) => origins
        _ =>
          raise ConfigFileError("listeners.ws_allowed_origins must be an array")
      }
      for origin in origins {
        add_string(
          args, "--listener-ws-allowed-origin", origin, "listeners.ws_allowed_origins",
        )
      }
    }
    if table.get("ws_require_origin") is Some(value) {
      add_boolean(
        args, "--listener-ws-require-origin", value, "listeners.ws_require_origin",
      )
    }
    for
      item in [
        ("http_upgrade_timeout_ms", "--listener-http-upgrade-timeout-ms"),
        ("max_http_header_bytes", "--listener-max-http-header-bytes"),
        ("max_ws_frame_bytes", "--listener-max-ws-frame-bytes"),
        ("max_ws_message_bytes", "--listener-max-ws-message-bytes"),
      ] {
      let (key, flag) = item
      if table.get(key) is Some(value) {
        add_integer(args, flag, value, "listeners." + key)
      }
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
    "server", "protocol", "broker", "persistence", "tls", "security", "observability",
    "resources", "limits", "management", "reload", "listeners",
  ]
  for section in sections {
    match root.get(section) {
      Some(value) =>
        if section == "listeners" {
          map_listeners(args, value)
        } else {
          map_section(args, section, value)
        }
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
