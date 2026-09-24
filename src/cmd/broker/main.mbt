///|
suberror CliError {
  CliError(String)
} derive(Debug)

///|
struct ListenerDraft {
  id : String
  mut transport : String
  mut listen : String
  mut max_connections : Int
  mut cert : String
  mut key : String
  mut handshake_timeout_ms : Int
  mut ws_path : String
  ws_allowed_origins : Array[String]
  mut ws_require_origin : Bool
  mut http_upgrade_timeout_ms : Int
  mut max_http_header_bytes : Int
  mut max_ws_frame_bytes : Int
  mut max_ws_message_bytes : Int
  mut ws_settings_used : Bool
}

///|
const RELEASE_VERSION : String = "0.2.0"

///|
fn print_help() -> Unit {
  println("moonbit-mqtt-broker " + RELEASE_VERSION)
  println("Usage: broker [OPTIONS]")
  println("")
  println("MQTT 3.1.1 QoS 0/1/2 Broker for Linux x86_64 Native.")
  println("The supported environment is the pinned Ubuntu 24.04 Docker image.")
  println("")
  println("Options:")
  println(
    "  -h, --help                         Show this help without starting the Broker",
  )
  println("  --version                          Show the release version")
  println("  --config PATH                      Load TOML configuration")
  println("  --check-config                     Validate without starting")
  println("  --print-effective-config           Print redacted effective TOML")
  println(
    "  --listen HOST:PORT                 Listener address (default 127.0.0.1:1883)",
  )
  println(
    "  --once                             Serve one connection, for smoke tests",
  )
  println(
    "  [[listeners]]                     Named tcp/tls/ws/wss listeners (max 16)",
  )
  println("  WS/WSS requires libcrypto.so.3; WSS also requires TLS libraries")
  println("  --management-enabled true|false  Default false")
  println("  --management-listen VALUE  Default 127.0.0.1:9091")
  println("  --management-token-file VALUE  Default unset")
  println("  --management-max-connections N  Default 16")
  println("  --management-max-header-bytes N  Default 4096")
  println("  --management-max-header-count N  Default 32")
  println("  --management-max-response-bytes N  Default 65536")
  println("  --management-request-timeout-ms N  Default 5000")
  println("  --management-write-timeout-ms N  Default 2000")
  println("  --management-snapshot-interval-ms N  Default 1000")
  println("  --management-snapshot-max-age-ms N  Default 5000")
  println(
    "  --management-ready-require-snapshot-healthy true|false  Default false",
  )
  println("  --management-request-rate N  Default 50")
  println("  --management-request-burst N  Default 100")
  println("  --management-connection-rate N  Default 100")
  println("  --management-connection-burst N  Default 200")
  println("  --management-details-enabled true|false  Default false")
  println("  --management-operations-enabled true|false  Default false")
  println("  --management-query-queue-limit N  Default 16")
  println("  --management-operation-queue-limit N  Default 16")
  println("  --management-max-operation-records N  Default 256")
  println("  --management-max-running-operations N  Default 8")
  println("  --management-operation-timeout-ms N  Default 30000")
  println("  --management-operation-retention-ms N  Default 900000")
  println("  --management-max-cursor-records N  Default 256")
  println("  --management-cursor-ttl-ms N  Default 60000")
  println("  --management-default-page-size N  Default 50")
  println("  --management-max-page-size N  Default 100")
  println("  --management-query-scan-limit N  Default 256")
  println("  --management-query-timeout-ms N  Default 2000")
  println("  --management-max-audit-records N  Default 1024")
  println("  --management-command-rate N  Default 5")
  println("  --management-command-burst N  Default 10")
  println("  --management-max-index-bytes N  Default 8388608")
  println("  --management-max-bytes-total N  Default 8388608")
  println("  --reload-enabled true|false  Default false")
  println("  --reload-manifest-file PATH  Fixed versioned bundle manifest")
  println("  --reload-material-runtime-dir PATH  Private TLS material root")
  println("  --reload-prepare-timeout-ms N  Default 30000")
  println("  --reload-max-source-bytes N  Default 16777216")
  println("  --reload-max-generation-bytes N  Default 67108864")
  println("  --reload-max-reconcile-items-per-turn N  Default 64")
  println("  --reload-max-reconcile-bytes-per-turn N  Default 1048576")
  println("  --reload-max-accounts N  Default 4096")
  println("  --reload-max-acl-rules N  Default 4096")
  println("  --max-connections N                Default 128")
  println("  --max-packet-size N                Default 1048576")
  println("  --max-receive-buffer-size N        Default 1048576")
  println("  --max-outbound-queue N             Default 64")
  println("  --max-runtime-events N             Default 512")
  println("  --connect-timeout-ms N             Default 10000")
  println("  --keep-alive-check-interval-ms N   Default 100")
  println("  --system-metrics-interval-ms N     Default 10000")
  println("  --auth-workers N                   Default 1")
  println("  --auth-queue-limit N               Default 16")
  println("  --auth-timeout-ms N                Default 10000")
  println("  --auth-poll-interval-ms N           Default 5")
  println("  --auth-result-batch-limit N         Default 16")
  println("  --auth-shutdown-grace-ms N          Default 10000")
  println("  --log-format text|json             Default text")
  println("  --log-level error|warn|info|debug  Default info")
  println("  --max-subscriptions-per-session N  Default 128")
  println("  --max-subscriptions-total N        Default 16384")
  println("  --max-retained-messages N          Default 1024")
  println("  --max-sessions N                   Default 1024")
  println("  --max-inflight-per-session N       Default 16")
  println("  --max-inflight-total N             Default 512")
  println("  --max-pending-per-session N        QoS 1/2, default 64")
  println("  --max-pending-total N              QoS 1/2, default 1024")
  println("  --max-inbound-qos2-per-session N   Default 64")
  println("  --max-inbound-qos2-total N         Default 4096")
  println("  --max-pending-qos1-per-session N   Legacy alias")
  println("  --max-pending-qos1-total N         Legacy alias")
  println("  --data-dir PATH                    Persistence data directory")
  println(
    "  --persistence-mode off|snapshot|strict  Default off without data-dir, snapshot with data-dir",
  )
  println("  --wal-disk-max-bytes N             Default 1073741824")
  println("  --wal-disk-reserve-bytes N         Default 268435456")
  println("  --max-snapshot-bytes N             Default 67108864")
  println("  --snapshot-debounce-ms N           Default 250")
  println("  --snapshot-max-delay-ms N          Default 2000")
  println("  --snapshot-retry-ms N              Default 1000")
  println("  --tls-cert PATH                    PEM certificate for TLS mode")
  println("  --tls-key PATH                     PEM private key for TLS mode")
  println("  --tls-handshake-timeout-ms N       Default 10000")
  println("  --allow-anonymous true|false       Default true")
  println("  --password-file PATH               Argon2id encoded password file")
  println("  --acl-file PATH                    Static allow-only topic ACL")
  println("  --persistent-session-expiry VALUE  never or duration: ms/s/m/h/d")
  println("  --max-session-expirations-per-tick N  Default 128")
  let resource_specs = @budget.byte_limit_specs()
  resource_specs.append(@budget.rate_limit_specs())
  for spec in resource_specs {
    let (_, key, value) = spec
    println(
      "  --" +
      key.replace_all(old="_", new="-") +
      " N  Default " +
      value.to_string(),
    )
  }
  println(
    "  --rate-limits-enabled true|false   Default true; zero rates do not refill",
  )
  println(
    "  --per-ip-limits-enabled true|false Default true; NAT clients share an IP",
  )
}

///|
fn parse_bool_option(
  args : Array[String],
  index : Int,
  name : String,
) -> Bool raise CliError {
  if index + 1 >= args.length() {
    raise CliError(name + " requires true or false")
  }
  match args[index + 1] {
    "true" => true
    "false" => false
    _ => raise CliError(name + " requires true or false")
  }
}

///|
fn parse_bounded_int(
  args : Array[String],
  index : Int,
  name : String,
  minimum : Int,
) -> Int raise CliError {
  if index + 1 >= args.length() {
    raise CliError(name + " requires an integer")
  }
  let value = @string.parse_int(args[index + 1]) catch {
    _ => raise CliError("invalid " + name)
  }
  if value < minimum {
    raise CliError(name + " must be at least " + minimum.to_string())
  }
  value
}

///|
fn parse_bounded_int64(
  args : Array[String],
  index : Int,
  name : String,
  minimum : Int64,
) -> Int64 raise CliError {
  if index + 1 >= args.length() {
    raise CliError(name + " requires an integer")
  }
  let value = @string.parse_int64(args[index + 1]) catch {
    _ => raise CliError("invalid " + name)
  }
  if value < minimum {
    raise CliError(name + " must be at least " + minimum.to_string())
  }
  value
}

///|
fn parse_session_expiry(value : String) -> Int64 raise CliError {
  if value == "never" {
    return -1L
  }
  let suffixes : Array[(String, Int64)] = [
    ("ms", 1L),
    ("s", 1000L),
    ("m", 60000L),
    ("h", 3600000L),
    ("d", 86400000L),
  ]
  for item in suffixes {
    let (suffix, multiplier) = item
    if value.has_suffix(suffix) && value.length() > suffix.length() {
      let count = @string.parse_int64(
        value[:value.length() - suffix.length()].to_owned(),
      ) catch {
        _ => raise CliError("invalid --persistent-session-expiry")
      }
      if count <= 0L || count > 9223372036854775807L / multiplier {
        raise CliError("invalid --persistent-session-expiry")
      }
      return count * multiplier
    }
  }
  raise CliError("invalid --persistent-session-expiry")
}

///|
async fn run_main() -> Unit {
  configure_shutdown_signals()
  let raw_args = @env.args()
  if raw_args.contains("-h") || raw_args.contains("--help") {
    print_help()
    return
  }
  if raw_args.contains("--version") {
    println(RELEASE_VERSION)
    return
  }
  let mut config_path : String? = None
  let mut loaded_config_text : String? = None
  let mut check_config = false
  let mut print_effective_config = false
  let cli_args : Array[String] = []
  let mut raw_index = 1
  while raw_index < raw_args.length() {
    match raw_args[raw_index] {
      "--config" => {
        if config_path is Some(_) {
          raise CliError("--config may only be specified once")
        }
        if raw_index + 1 >= raw_args.length() {
          raise CliError("--config requires a path")
        }
        config_path = Some(raw_args[raw_index + 1])
        raw_index = raw_index + 2
      }
      "--check-config" => {
        check_config = true
        raw_index = raw_index + 1
      }
      "--print-effective-config" => {
        print_effective_config = true
        raw_index = raw_index + 1
      }
      value => {
        cli_args.push(value)
        raw_index = raw_index + 1
      }
    }
  }
  if check_config && print_effective_config {
    raise CliError(
      "--check-config and --print-effective-config are mutually exclusive",
    )
  }
  let file_args = match config_path {
    None => []
    Some(path) => {
      let kind = @fs.kind(path, follow_symlink=false) catch {
        _ => raise CliError("--config must name a readable regular file")
      }
      if kind != @fs.Regular {
        raise CliError("--config must name a readable regular file")
      }
      let bytes = @fs.read_file(path) catch {
        _ => raise CliError("failed to read --config")
      }
      if bytes.binary().length() > 1048576 {
        raise CliError("--config exceeds 1048576 bytes")
      }
      let contents = bytes.text() catch {
        _ => raise CliError("--config must be UTF-8")
      }
      loaded_config_text = Some(contents)
      @config.parse_config_file(contents) catch {
        @config.ConfigFileError(message) =>
          raise CliError("configuration file: " + message)
      }
    }
  }
  for suffix in ["per-session", "total"] {
    if cli_args.contains("--max-pending-" + suffix) &&
      cli_args.contains("--max-pending-qos1-" + suffix) {
      raise CliError("conflicting pending limit aliases: " + suffix)
    }
  }
  let args : Array[String] = [raw_args[0]]
  args.append(file_args)
  args.append(cli_args)
  let explicit_resources : Map[String, Bool] = Map([])
  let mut resources = @budget.Limits::default()
  let resource_specs = @budget.byte_limit_specs()
  resource_specs.append(@budget.rate_limit_specs())
  let mut listen = "127.0.0.1:1883"
  let mut legacy_listen_explicit = false
  let mut legacy_tls_explicit = false
  let listener_drafts : Array[ListenerDraft] = []
  let mut max_connections = 128
  let mut max_packet_size = 1048576
  let mut max_receive_buffer_size = 1048576
  let mut max_outbound_queue = 64
  let mut max_runtime_events = 512
  let mut connect_timeout_ms = 10000
  let mut keep_alive_check_interval_ms = 100
  let mut system_metrics_interval_ms = 10000
  let mut auth_workers = 1
  let mut auth_queue_limit = 16
  let mut auth_timeout_ms = 10000
  let mut auth_poll_interval_ms = 5
  let mut auth_result_batch_limit = 16
  let mut auth_shutdown_grace_ms = 10000
  let mut max_subscriptions_per_session = 128
  let mut max_subscriptions_total = 16384
  let mut max_retained_messages = 1024
  let mut max_sessions = 1024
  let mut max_inflight_per_session = 16
  let mut max_inflight_total = 512
  let mut max_pending_qos1_per_session = 64
  let mut max_pending_qos1_total = 1024
  let mut max_inbound_qos2_per_session = 64
  let mut max_inbound_qos2_total = 4096
  let mut data_dir : String? = None
  let mut persistence_mode = "auto"
  let mut wal_disk_max_bytes = 1073741824L
  let mut wal_disk_reserve_bytes = 268435456L
  let mut wal_option_used = false
  let mut snapshot_timing_option_used = false
  let mut max_snapshot_bytes = 67108864L
  let mut snapshot_debounce_ms = 250L
  let mut snapshot_max_delay_ms = 2000L
  let mut snapshot_retry_ms = 1000L
  let mut snapshot_option_used = false
  let mut tls_certificate_file : String? = None
  let mut tls_private_key_file : String? = None
  let mut tls_handshake_timeout_ms = 10000
  let mut tls_timeout_option_used = false
  let mut allow_anonymous = true
  let mut password_file : String? = None
  let mut acl_file : String? = None
  let mut persistent_session_expiry_ms = -1L
  let mut max_session_expirations_per_tick = 128
  let mut log_format = @observability.Text
  let mut log_level = @observability.Info
  let mut management_enabled = false
  let mut management_listen = "127.0.0.1:9091"
  let mut management_token_file = ""
  let mut management_max_connections = 16
  let mut management_max_header_bytes = 4096
  let mut management_max_header_count = 32
  let mut management_max_response_bytes = 65536
  let mut management_request_timeout_ms = 5000
  let mut management_write_timeout_ms = 2000
  let mut management_snapshot_interval_ms = 1000
  let mut management_snapshot_max_age_ms = 5000
  let mut management_ready_require_snapshot_healthy = false
  let mut management_request_rate = 50
  let mut management_request_burst = 100
  let mut management_connection_rate = 100
  let mut management_connection_burst = 200
  let mut management_details_enabled = false
  let mut management_operations_enabled = false
  let mut management_query_queue_limit = 16
  let mut management_operation_queue_limit = 16
  let mut management_max_operation_records = 256
  let mut management_max_running_operations = 8
  let mut management_operation_timeout_ms = 30000
  let mut management_operation_retention_ms = 900000
  let mut management_max_cursor_records = 256
  let mut management_cursor_ttl_ms = 60000
  let mut management_default_page_size = 50
  let mut management_max_page_size = 100
  let mut management_query_scan_limit = 256
  let mut management_query_timeout_ms = 2000
  let mut management_max_audit_records = 1024
  let mut management_command_rate = 5
  let mut management_command_burst = 10
  let mut management_max_index_bytes = 8388608L
  let mut management_max_bytes_total = 8388608L
  let mut reload_enabled = false
  let mut reload_manifest_file = ""
  let mut reload_material_runtime_dir = ""
  let mut reload_prepare_timeout_ms = 30000
  let mut reload_max_source_bytes = 16777216
  let mut reload_max_generation_bytes = 67108864L
  let mut reload_max_reconcile_items_per_turn = 64
  let mut reload_max_reconcile_bytes_per_turn = 1048576
  let mut reload_max_accounts = 4096
  let mut reload_max_acl_rules = 4096
  let mut once = false
  let mut index = 1
  while index < args.length() {
    match args[index] {
      "-h" | "--help" => {
        print_help()
        return
      }
      "--version" => {
        println(RELEASE_VERSION)
        return
      }
      "--listen" => {
        if index + 1 >= args.length() {
          raise CliError("--listen requires HOST:PORT")
        }
        listen = args[index + 1]
        legacy_listen_explicit = true
        index = index + 2
      }
      "--max-connections" => {
        max_connections = parse_bounded_int(args, index, "--max-connections", 1)
        index = index + 2
      }
      "--max-packet-size" => {
        max_packet_size = parse_bounded_int(args, index, "--max-packet-size", 2)
        index = index + 2
      }
      "--max-receive-buffer-size" => {
        max_receive_buffer_size = parse_bounded_int(
          args, index, "--max-receive-buffer-size", 2,
        )
        index = index + 2
      }
      "--max-outbound-queue" => {
        max_outbound_queue = parse_bounded_int(
          args, index, "--max-outbound-queue", 1,
        )
        index = index + 2
      }
      "--max-runtime-events" => {
        max_runtime_events = parse_bounded_int(
          args, index, "--max-runtime-events", 1,
        )
        index = index + 2
      }
      "--connect-timeout-ms" => {
        connect_timeout_ms = parse_bounded_int(
          args, index, "--connect-timeout-ms", 1,
        )
        index = index + 2
      }
      "--keep-alive-check-interval-ms" => {
        keep_alive_check_interval_ms = parse_bounded_int(
          args, index, "--keep-alive-check-interval-ms", 1,
        )
        index = index + 2
      }
      "--system-metrics-interval-ms" => {
        system_metrics_interval_ms = parse_bounded_int(
          args, index, "--system-metrics-interval-ms", 1,
        )
        index = index + 2
      }
      "--auth-workers" => {
        auth_workers = parse_bounded_int(args, index, "--auth-workers", 1)
        index += 2
      }
      "--auth-queue-limit" => {
        auth_queue_limit = parse_bounded_int(
          args, index, "--auth-queue-limit", 0,
        )
        index += 2
      }
      "--auth-timeout-ms" => {
        auth_timeout_ms = parse_bounded_int(args, index, "--auth-timeout-ms", 1)
        index += 2
      }
      "--auth-poll-interval-ms" => {
        auth_poll_interval_ms = parse_bounded_int(
          args, index, "--auth-poll-interval-ms", 1,
        )
        index += 2
      }
      "--auth-result-batch-limit" => {
        auth_result_batch_limit = parse_bounded_int(
          args, index, "--auth-result-batch-limit", 1,
        )
        index += 2
      }
      "--auth-shutdown-grace-ms" => {
        auth_shutdown_grace_ms = parse_bounded_int(
          args, index, "--auth-shutdown-grace-ms", 1,
        )
        index += 2
      }
      "--log-format" => {
        if index + 1 >= args.length() {
          raise CliError("--log-format requires text or json")
        }
        log_format = match args[index + 1] {
          "text" => @observability.Text
          "json" => @observability.Json
          _ => raise CliError("--log-format requires text or json")
        }
        index = index + 2
      }
      "--log-level" => {
        if index + 1 >= args.length() {
          raise CliError("--log-level requires error, warn, info, or debug")
        }
        log_level = match args[index + 1] {
          "error" => @observability.Error
          "warn" => @observability.Warn
          "info" => @observability.Info
          "debug" => @observability.Debug
          _ =>
            raise CliError("--log-level requires error, warn, info, or debug")
        }
        index = index + 2
      }
      "--max-subscriptions-per-session" => {
        max_subscriptions_per_session = parse_bounded_int(
          args, index, "--max-subscriptions-per-session", 1,
        )
        index = index + 2
      }
      "--max-subscriptions-total" => {
        max_subscriptions_total = parse_bounded_int(
          args, index, "--max-subscriptions-total", 1,
        )
        index = index + 2
      }
      "--max-retained-messages" => {
        max_retained_messages = parse_bounded_int(
          args, index, "--max-retained-messages", 1,
        )
        index = index + 2
      }
      "--max-sessions" => {
        max_sessions = parse_bounded_int(args, index, "--max-sessions", 0)
        index = index + 2
      }
      "--max-inflight-per-session" => {
        max_inflight_per_session = parse_bounded_int(
          args, index, "--max-inflight-per-session", 0,
        )
        index = index + 2
      }
      "--max-inflight-total" => {
        max_inflight_total = parse_bounded_int(
          args, index, "--max-inflight-total", 0,
        )
        index = index + 2
      }
      "--max-pending-qos1-per-session" | "--max-pending-per-session" => {
        max_pending_qos1_per_session = parse_bounded_int(
          args, index, "--max-pending-qos1-per-session", 0,
        )
        index = index + 2
      }
      "--max-pending-qos1-total" | "--max-pending-total" => {
        max_pending_qos1_total = parse_bounded_int(
          args, index, "--max-pending-qos1-total", 0,
        )
        index = index + 2
      }
      "--max-inbound-qos2-per-session" => {
        max_inbound_qos2_per_session = parse_bounded_int(
          args, index, "--max-inbound-qos2-per-session", 0,
        )
        index += 2
      }
      "--max-inbound-qos2-total" => {
        max_inbound_qos2_total = parse_bounded_int(
          args, index, "--max-inbound-qos2-total", 0,
        )
        index += 2
      }
      "--data-dir" => {
        if index + 1 >= args.length() || args[index + 1] == "" {
          raise CliError("--data-dir requires a non-empty path")
        }
        data_dir = Some(args[index + 1])
        index = index + 2
      }
      "--persistence-mode" => {
        if index + 1 >= args.length() ||
          !(args[index + 1] == "off" ||
          args[index + 1] == "snapshot" ||
          args[index + 1] == "strict") {
          raise CliError("--persistence-mode must be off, snapshot or strict")
        }
        persistence_mode = args[index + 1]
        index += 2
      }
      "--wal-disk-max-bytes" => {
        wal_disk_max_bytes = parse_bounded_int64(
          args, index, "--wal-disk-max-bytes", 335544320L,
        )
        wal_option_used = true
        index += 2
      }
      "--wal-disk-reserve-bytes" => {
        wal_disk_reserve_bytes = parse_bounded_int64(
          args, index, "--wal-disk-reserve-bytes", 268435456L,
        )
        wal_option_used = true
        index += 2
      }
      "--max-snapshot-bytes" => {
        max_snapshot_bytes = parse_bounded_int64(
          args, index, "--max-snapshot-bytes", 24L,
        )
        snapshot_option_used = true
        index = index + 2
      }
      "--snapshot-debounce-ms" => {
        snapshot_debounce_ms = parse_bounded_int64(
          args, index, "--snapshot-debounce-ms", 1L,
        )
        snapshot_option_used = true
        snapshot_timing_option_used = true
        index = index + 2
      }
      "--snapshot-max-delay-ms" => {
        snapshot_max_delay_ms = parse_bounded_int64(
          args, index, "--snapshot-max-delay-ms", 1L,
        )
        snapshot_option_used = true
        snapshot_timing_option_used = true
        index = index + 2
      }
      "--snapshot-retry-ms" => {
        snapshot_retry_ms = parse_bounded_int64(
          args, index, "--snapshot-retry-ms", 1L,
        )
        snapshot_option_used = true
        snapshot_timing_option_used = true
        index = index + 2
      }
      "--tls-cert" => {
        if index + 1 >= args.length() || args[index + 1] == "" {
          raise CliError("--tls-cert requires a non-empty path")
        }
        tls_certificate_file = Some(args[index + 1])
        legacy_tls_explicit = true
        index = index + 2
      }
      "--tls-key" => {
        if index + 1 >= args.length() || args[index + 1] == "" {
          raise CliError("--tls-key requires a non-empty path")
        }
        tls_private_key_file = Some(args[index + 1])
        legacy_tls_explicit = true
        index = index + 2
      }
      "--tls-handshake-timeout-ms" => {
        tls_handshake_timeout_ms = parse_bounded_int(
          args, index, "--tls-handshake-timeout-ms", 1,
        )
        tls_timeout_option_used = true
        legacy_tls_explicit = true
        index = index + 2
      }
      "--allow-anonymous" => {
        if index + 1 >= args.length() {
          raise CliError("--allow-anonymous requires true or false")
        }
        allow_anonymous = match args[index + 1] {
          "true" => true
          "false" => false
          _ => raise CliError("--allow-anonymous requires true or false")
        }
        index = index + 2
      }
      "--password-file" => {
        if index + 1 >= args.length() || args[index + 1] == "" {
          raise CliError("--password-file requires a non-empty path")
        }
        password_file = Some(args[index + 1])
        index = index + 2
      }
      "--acl-file" => {
        if index + 1 >= args.length() || args[index + 1] == "" {
          raise CliError("--acl-file requires a non-empty path")
        }
        acl_file = Some(args[index + 1])
        index = index + 2
      }
      "--persistent-session-expiry" => {
        if index + 1 >= args.length() {
          raise CliError("--persistent-session-expiry requires a value")
        }
        persistent_session_expiry_ms = parse_session_expiry(args[index + 1])
        index = index + 2
      }
      "--max-session-expirations-per-tick" => {
        max_session_expirations_per_tick = parse_bounded_int(
          args, index, "--max-session-expirations-per-tick", 1,
        )
        index = index + 2
      }
      "--management-enabled" => {
        management_enabled = parse_bool_option(
          args, index, "--management-enabled",
        )
        index += 2
      }
      "--management-listen" => {
        if index + 1 >= args.length() {
          raise CliError("--management-listen requires a value")
        }
        management_listen = args[index + 1]
        index += 2
      }
      "--management-token-file" => {
        if index + 1 >= args.length() {
          raise CliError("--management-token-file requires a value")
        }
        management_token_file = args[index + 1]
        index += 2
      }
      "--management-max-connections" => {
        management_max_connections = parse_bounded_int(
          args, index, "--management-max-connections", 1,
        )
        index += 2
      }
      "--management-max-header-bytes" => {
        management_max_header_bytes = parse_bounded_int(
          args, index, "--management-max-header-bytes", 1,
        )
        index += 2
      }
      "--management-max-header-count" => {
        management_max_header_count = parse_bounded_int(
          args, index, "--management-max-header-count", 1,
        )
        index += 2
      }
      "--management-max-response-bytes" => {
        management_max_response_bytes = parse_bounded_int(
          args, index, "--management-max-response-bytes", 1,
        )
        index += 2
      }
      "--management-request-timeout-ms" => {
        management_request_timeout_ms = parse_bounded_int(
          args, index, "--management-request-timeout-ms", 1,
        )
        index += 2
      }
      "--management-write-timeout-ms" => {
        management_write_timeout_ms = parse_bounded_int(
          args, index, "--management-write-timeout-ms", 1,
        )
        index += 2
      }
      "--management-snapshot-interval-ms" => {
        management_snapshot_interval_ms = parse_bounded_int(
          args, index, "--management-snapshot-interval-ms", 1,
        )
        index += 2
      }
      "--management-snapshot-max-age-ms" => {
        management_snapshot_max_age_ms = parse_bounded_int(
          args, index, "--management-snapshot-max-age-ms", 1,
        )
        index += 2
      }
      "--management-ready-require-snapshot-healthy" => {
        management_ready_require_snapshot_healthy = parse_bool_option(
          args, index, "--management-ready-require-snapshot-healthy",
        )
        index += 2
      }
      "--management-request-rate" => {
        management_request_rate = parse_bounded_int(
          args, index, "--management-request-rate", 1,
        )
        index += 2
      }
      "--management-request-burst" => {
        management_request_burst = parse_bounded_int(
          args, index, "--management-request-burst", 1,
        )
        index += 2
      }
      "--management-connection-rate" => {
        management_connection_rate = parse_bounded_int(
          args, index, "--management-connection-rate", 1,
        )
        index += 2
      }
      "--management-connection-burst" => {
        management_connection_burst = parse_bounded_int(
          args, index, "--management-connection-burst", 1,
        )
        index += 2
      }
      "--management-details-enabled" => {
        management_details_enabled = parse_bool_option(
          args, index, "--management-details-enabled",
        )
        index += 2
      }
      "--management-operations-enabled" => {
        management_operations_enabled = parse_bool_option(
          args, index, "--management-operations-enabled",
        )
        index += 2
      }
      "--management-query-queue-limit" => {
        management_query_queue_limit = parse_bounded_int(
          args, index, "--management-query-queue-limit", 1,
        )
        index += 2
      }
      "--management-operation-queue-limit" => {
        management_operation_queue_limit = parse_bounded_int(
          args, index, "--management-operation-queue-limit", 1,
        )
        index += 2
      }
      "--management-max-operation-records" => {
        management_max_operation_records = parse_bounded_int(
          args, index, "--management-max-operation-records", 1,
        )
        index += 2
      }
      "--management-max-running-operations" => {
        management_max_running_operations = parse_bounded_int(
          args, index, "--management-max-running-operations", 1,
        )
        index += 2
      }
      "--management-operation-timeout-ms" => {
        management_operation_timeout_ms = parse_bounded_int(
          args, index, "--management-operation-timeout-ms", 1,
        )
        index += 2
      }
      "--management-operation-retention-ms" => {
        management_operation_retention_ms = parse_bounded_int(
          args, index, "--management-operation-retention-ms", 1,
        )
        index += 2
      }
      "--management-max-cursor-records" => {
        management_max_cursor_records = parse_bounded_int(
          args, index, "--management-max-cursor-records", 1,
        )
        index += 2
      }
      "--management-cursor-ttl-ms" => {
        management_cursor_ttl_ms = parse_bounded_int(
          args, index, "--management-cursor-ttl-ms", 1,
        )
        index += 2
      }
      "--management-default-page-size" => {
        management_default_page_size = parse_bounded_int(
          args, index, "--management-default-page-size", 1,
        )
        index += 2
      }
      "--management-max-page-size" => {
        management_max_page_size = parse_bounded_int(
          args, index, "--management-max-page-size", 1,
        )
        index += 2
      }
      "--management-query-scan-limit" => {
        management_query_scan_limit = parse_bounded_int(
          args, index, "--management-query-scan-limit", 1,
        )
        index += 2
      }
      "--management-query-timeout-ms" => {
        management_query_timeout_ms = parse_bounded_int(
          args, index, "--management-query-timeout-ms", 1,
        )
        index += 2
      }
      "--management-max-audit-records" => {
        management_max_audit_records = parse_bounded_int(
          args, index, "--management-max-audit-records", 1,
        )
        index += 2
      }
      "--management-command-rate" => {
        management_command_rate = parse_bounded_int(
          args, index, "--management-command-rate", 1,
        )
        index += 2
      }
      "--management-command-burst" => {
        management_command_burst = parse_bounded_int(
          args, index, "--management-command-burst", 1,
        )
        index += 2
      }
      "--management-max-index-bytes" => {
        management_max_index_bytes = parse_bounded_int64(
          args, index, "--management-max-index-bytes", 1L,
        )
        index += 2
      }
      "--management-max-bytes-total" => {
        management_max_bytes_total = parse_bounded_int64(
          args, index, "--management-max-bytes-total", 1L,
        )
        index += 2
      }
      "--reload-enabled" => {
        reload_enabled = parse_bool_option(args, index, "--reload-enabled")
        index += 2
      }
      "--reload-manifest-file" => {
        if index + 1 >= args.length() {
          raise CliError("--reload-manifest-file requires a path")
        }
        reload_manifest_file = args[index + 1]
        index += 2
      }
      "--reload-material-runtime-dir" => {
        if index + 1 >= args.length() {
          raise CliError("--reload-material-runtime-dir requires a path")
        }
        reload_material_runtime_dir = args[index + 1]
        index += 2
      }
      "--reload-prepare-timeout-ms" => {
        reload_prepare_timeout_ms = parse_bounded_int(
          args, index, "--reload-prepare-timeout-ms", 1,
        )
        index += 2
      }
      "--reload-max-source-bytes" => {
        reload_max_source_bytes = parse_bounded_int(
          args, index, "--reload-max-source-bytes", 16384,
        )
        index += 2
      }
      "--reload-max-generation-bytes" => {
        reload_max_generation_bytes = parse_bounded_int64(
          args, index, "--reload-max-generation-bytes", 1L,
        )
        index += 2
      }
      "--reload-max-reconcile-items-per-turn" => {
        reload_max_reconcile_items_per_turn = parse_bounded_int(
          args, index, "--reload-max-reconcile-items-per-turn", 1,
        )
        index += 2
      }
      "--reload-max-reconcile-bytes-per-turn" => {
        reload_max_reconcile_bytes_per_turn = parse_bounded_int(
          args, index, "--reload-max-reconcile-bytes-per-turn", 131328,
        )
        index += 2
      }
      "--reload-max-accounts" => {
        reload_max_accounts = parse_bounded_int(
          args, index, "--reload-max-accounts", 1,
        )
        index += 2
      }
      "--reload-max-acl-rules" => {
        reload_max_acl_rules = parse_bounded_int(
          args, index, "--reload-max-acl-rules", 1,
        )
        index += 2
      }
      "--listener-id" => {
        if index + 1 >= args.length() || args[index + 1] == "" {
          raise CliError("--listener-id requires a non-empty ID")
        }
        listener_drafts.push({
          id: args[index + 1],
          transport: "",
          listen: "",
          max_connections: -1,
          cert: "",
          key: "",
          handshake_timeout_ms: 10000,
          ws_path: "/mqtt",
          ws_allowed_origins: [],
          ws_require_origin: false,
          http_upgrade_timeout_ms: 5000,
          max_http_header_bytes: 16384,
          max_ws_frame_bytes: 1048576,
          max_ws_message_bytes: 4194304,
          ws_settings_used: false,
        })
        index += 2
      }
      "--listener-transport"
      | "--listener-listen"
      | "--listener-max-connections"
      | "--listener-tls-cert"
      | "--listener-tls-key"
      | "--listener-tls-handshake-timeout-ms"
      | "--listener-ws-path"
      | "--listener-ws-allowed-origin"
      | "--listener-ws-require-origin"
      | "--listener-http-upgrade-timeout-ms"
      | "--listener-max-http-header-bytes"
      | "--listener-max-ws-frame-bytes"
      | "--listener-max-ws-message-bytes" => {
        if listener_drafts.is_empty() || index + 1 >= args.length() {
          raise CliError(
            args[index] + " requires a preceding --listener-id and value",
          )
        }
        let draft = listener_drafts[listener_drafts.length() - 1]
        match args[index] {
          "--listener-transport" => draft.transport = args[index + 1]
          "--listener-listen" => draft.listen = args[index + 1]
          "--listener-max-connections" =>
            draft.max_connections = parse_bounded_int(
              args, index, "--listener-max-connections", 1,
            )
          "--listener-tls-cert" => draft.cert = args[index + 1]
          "--listener-tls-key" => draft.key = args[index + 1]
          "--listener-tls-handshake-timeout-ms" =>
            draft.handshake_timeout_ms = parse_bounded_int(
              args, index, "--listener-tls-handshake-timeout-ms", 1,
            )
          "--listener-ws-path" => {
            draft.ws_path = args[index + 1]
            draft.ws_settings_used = true
          }
          "--listener-ws-allowed-origin" => {
            draft.ws_allowed_origins.push(args[index + 1])
            draft.ws_settings_used = true
          }
          "--listener-ws-require-origin" => {
            draft.ws_require_origin = parse_bool_option(
              args, index, "--listener-ws-require-origin",
            )
            draft.ws_settings_used = true
          }
          "--listener-http-upgrade-timeout-ms" => {
            draft.http_upgrade_timeout_ms = parse_bounded_int(
              args, index, "--listener-http-upgrade-timeout-ms", 1,
            )
            draft.ws_settings_used = true
          }
          "--listener-max-http-header-bytes" => {
            draft.max_http_header_bytes = parse_bounded_int(
              args, index, "--listener-max-http-header-bytes", 1,
            )
            draft.ws_settings_used = true
          }
          "--listener-max-ws-frame-bytes" => {
            draft.max_ws_frame_bytes = parse_bounded_int(
              args, index, "--listener-max-ws-frame-bytes", 1,
            )
            draft.ws_settings_used = true
          }
          _ => {
            draft.max_ws_message_bytes = parse_bounded_int(
              args, index, "--listener-max-ws-message-bytes", 1,
            )
            draft.ws_settings_used = true
          }
        }
        index += 2
      }
      "--once" => {
        once = true
        index = index + 1
      }
      value => {
        if value == "--rate-limits-enabled" ||
          value == "--per-ip-limits-enabled" {
          if index + 1 >= args.length() {
            raise CliError(value + " requires true or false")
          }
          let enabled = match args[index + 1] {
            "true" => 1L
            "false" => 0L
            _ => raise CliError(value + " requires true or false")
          }
          resources = resources
            .with_value(
              if value == "--rate-limits-enabled" {
                "rate_limits_enabled"
              } else {
                "per_ip_limits_enabled"
              },
              enabled,
            )
            .unwrap()
        } else {
          let mut found = false
          for spec in resource_specs {
            let (_, key, _) = spec
            if value == "--" + key.replace_all(old="_", new="-") {
              let parsed = parse_bounded_int64(args, index, value, 0L)
              resources = resources.with_value(key, parsed).unwrap()
              explicit_resources.set(key, true)
              found = true
              break
            }
          }
          if !found {
            raise CliError("unknown argument: " + value)
          }
        }
        index += 2
      }
    }
  }
  if !explicit_resources.contains("max_retained_message_bytes") {
    resources = resources
      .with_value("max_retained_message_bytes", max_packet_size.to_int64())
      .unwrap()
  }
  if !explicit_resources.contains("max_will_bytes_per_connection") {
    resources = resources
      .with_value("max_will_bytes_per_connection", max_packet_size.to_int64())
      .unwrap()
  }
  let broker_config = match
    @router.BrokerConfig::new(
      max_subscriptions_per_session,
      max_subscriptions_total,
      max_retained_messages,
      max_sessions~,
      resources~,
      max_inflight_per_session~,
      max_inflight_total~,
      max_pending_qos1_per_session~,
      max_pending_qos1_total~,
      max_inbound_qos2_per_session~,
      max_inbound_qos2_total~,
      persistent_session_expiry_ms~,
      max_session_expirations_per_tick~,
    ) {
    Ok(value) => value
    Err(_) => raise CliError("invalid broker resource configuration")
  }
  if max_receive_buffer_size < max_packet_size {
    raise CliError(
      "--max-receive-buffer-size must be at least --max-packet-size",
    )
  }
  if keep_alive_check_interval_ms > connect_timeout_ms {
    raise CliError(
      "--keep-alive-check-interval-ms must not exceed --connect-timeout-ms",
    )
  }
  let config = match
    @server.ServerConfig::new(
      max_connections,
      max_packet_size,
      max_receive_buffer_size,
      max_outbound_queue,
      max_runtime_events,
      connect_timeout_ms,
      keep_alive_check_interval_ms,
      broker_config,
      system_metrics_interval_ms~,
      auth_workers~,
      auth_queue_limit~,
      auth_timeout_ms~,
      auth_poll_interval_ms~,
      auth_result_batch_limit~,
      auth_shutdown_grace_ms~,
    ) {
    Ok(value) => value
    Err(_) => raise CliError("invalid server configuration")
  }
  let management_config = match
    @management.ManagementConfig::new(
      enabled=management_enabled,
      listen=management_listen,
      token_file=management_token_file,
      max_connections=management_max_connections,
      max_header_bytes=management_max_header_bytes,
      max_header_count=management_max_header_count,
      max_response_bytes=management_max_response_bytes,
      request_timeout_ms=management_request_timeout_ms,
      write_timeout_ms=management_write_timeout_ms,
      snapshot_interval_ms=management_snapshot_interval_ms,
      snapshot_max_age_ms=management_snapshot_max_age_ms,
      ready_require_snapshot_healthy=management_ready_require_snapshot_healthy,
      request_rate=management_request_rate,
      request_burst=management_request_burst,
      connection_rate=management_connection_rate,
      connection_burst=management_connection_burst,
      details_enabled=management_details_enabled,
      operations_enabled=management_operations_enabled,
      query_queue_limit=management_query_queue_limit,
      operation_queue_limit=management_operation_queue_limit,
      max_operation_records=management_max_operation_records,
      max_running_operations=management_max_running_operations,
      operation_timeout_ms=management_operation_timeout_ms,
      operation_retention_ms=management_operation_retention_ms,
      max_cursor_records=management_max_cursor_records,
      cursor_ttl_ms=management_cursor_ttl_ms,
      default_page_size=management_default_page_size,
      max_page_size=management_max_page_size,
      query_scan_limit=management_query_scan_limit,
      query_timeout_ms=management_query_timeout_ms,
      max_audit_records=management_max_audit_records,
      command_rate=management_command_rate,
      command_burst=management_command_burst,
      max_index_bytes=management_max_index_bytes,
      max_bytes_total=management_max_bytes_total,
    ) {
    Ok(value) => value
    Err(@management.ManagementConfigError::Invalid(field)) =>
      raise CliError("invalid management." + field)
  }
  if once && management_config.enabled() {
    raise CliError("--once cannot be combined with management.enabled")
  }
  let management_tokens = if management_config.enabled() {
    let tokens = match
      @management.TokenDatabase::load(management_config.token_file()) {
      Ok(value) => value
      Err(@management.TokenError::CryptoUnavailable) =>
        raise CliError("management authentication requires libcrypto.so.3")
      Err(@management.TokenError::TokenFileMissing) =>
        raise CliError("management token file is unavailable")
      Err(@management.TokenError::TokenFileTooLarge) =>
        raise CliError("management token file exceeds 16384 bytes")
      Err(@management.TokenError::TokenFileUnsafe) =>
        raise CliError(
          "management token file must be a private regular file owned by the broker user",
        )
      Err(@management.TokenError::InvalidTokenFile) =>
        raise CliError("invalid management token file")
    }
    Some(tokens)
  } else {
    None
  }
  let use_captured_tls = reload_enabled || reload_manifest_file != ""
  let tls = match (tls_certificate_file, tls_private_key_file) {
    (None, None) => {
      if tls_timeout_option_used {
        raise CliError(
          "--tls-handshake-timeout-ms requires --tls-cert and --tls-key",
        )
      }
      None
    }
    (Some(certificate_file), Some(private_key_file)) => {
      if !use_captured_tls {
        let certificate_kind = @fs.kind(certificate_file, follow_symlink=false) catch {
          _ => raise CliError("--tls-cert must name a readable regular file")
        }
        if certificate_kind != @fs.Regular {
          raise CliError("--tls-cert must name a readable regular file")
        }
        match private_key_status(private_key_file) {
          0 => ()
          1 => raise CliError("--tls-key must name a readable regular file")
          2 =>
            raise CliError(
              "--tls-key must be a regular file, not a symlink or special file",
            )
          3 =>
            raise CliError(
              "--tls-key must not grant permissions to group or other users",
            )
          _ => raise CliError("--tls-key validation failed")
        }
      }
      let value = @server.TlsServerConfig::new(
        certificate_file,
        private_key_file,
        handshake_timeout_ms=tls_handshake_timeout_ms,
      ).unwrap()
      if !use_captured_tls {
        @server.validate_tls_config(value) catch {
          _ => raise CliError("TLS certificate/private key validation failed")
        }
      }
      Some(value)
    }
    (Some(_), None) => raise CliError("--tls-cert requires --tls-key")
    (None, Some(_)) => raise CliError("--tls-key requires --tls-cert")
  }
  let effective_listeners : Array[@server.ListenerConfig] = []
  if listener_drafts.is_empty() {
    let single = match
      @server.ListenerConfig::new("mqtt", listen, max_connections, tls?) {
      Ok(value) => value
      Err(_) => raise CliError("invalid --listen address")
    }
    effective_listeners.push(single)
  } else {
    if legacy_listen_explicit || legacy_tls_explicit {
      raise CliError(
        "listeners cannot be combined with legacy --listen or --tls-*",
      )
    }
    if once && listener_drafts.length() != 1 {
      raise CliError("--once requires exactly one listener")
    }
    let ids : Map[String, Bool] = Map([])
    for draft in listener_drafts {
      if ids.contains(draft.id) {
        raise CliError("duplicate listener id: " + draft.id)
      }
      ids.set(draft.id, true)
      if draft.listen == "" {
        raise CliError("listener " + draft.id + " requires listen")
      }
      let cap = if draft.max_connections < 0 {
        max_connections
      } else {
        draft.max_connections
      }
      if cap > max_connections {
        raise CliError(
          "listener " + draft.id + " exceeds global max_connections",
        )
      }
      let needs_tls = draft.transport == "tls" || draft.transport == "wss"
      let needs_ws = draft.transport == "ws" || draft.transport == "wss"
      if !(draft.transport == "tcp" || needs_tls || needs_ws) {
        raise CliError("listener transport must be tcp, tls, ws, or wss")
      }
      let listener_tls : @server.TlsServerConfig? = if needs_tls {
        if draft.cert == "" || draft.key == "" {
          raise CliError("TLS listener requires tls_cert and tls_key")
        }
        if !use_captured_tls {
          let certificate_kind = @fs.kind(draft.cert, follow_symlink=false) catch {
            _ => raise CliError("listener TLS certificate is unavailable")
          }
          if certificate_kind != @fs.Regular ||
            private_key_status(draft.key) != 0 {
            raise CliError("listener TLS material must be safe regular files")
          }
        }
        let value = @server.TlsServerConfig::new(
          draft.cert,
          draft.key,
          handshake_timeout_ms=draft.handshake_timeout_ms,
        ).unwrap()
        if !use_captured_tls {
          @server.validate_tls_config(value) catch {
            _ =>
              raise CliError(
                "listener TLS certificate/private key validation failed",
              )
          }
        }
        Some(value)
      } else {
        if draft.cert != "" ||
          draft.key != "" ||
          draft.handshake_timeout_ms != 10000 {
          raise CliError("non-TLS listener cannot specify TLS settings")
        }
        None
      }
      let websocket : @server.WebSocketPolicy? = if needs_ws {
        if !@server.websocket_crypto_ready() {
          raise CliError("WS/WSS requires libcrypto.so.3")
        }
        match
          @server.WebSocketPolicy::new(
            path=draft.ws_path,
            allowed_origins=draft.ws_allowed_origins,
            require_origin=draft.ws_require_origin,
            max_header_bytes=draft.max_http_header_bytes,
            upgrade_timeout_ms=draft.http_upgrade_timeout_ms,
            max_frame_bytes=draft.max_ws_frame_bytes,
            max_message_bytes=draft.max_ws_message_bytes,
          ) {
          Some(value) => Some(value)
          None => raise CliError("invalid listener WS policy")
        }
      } else {
        if draft.ws_settings_used {
          raise CliError("non-WS listener cannot specify WS settings")
        }
        None
      }
      let config = match
        @server.ListenerConfig::new(
          draft.id,
          draft.listen,
          cap,
          tls?=listener_tls,
          transport=draft.transport,
          websocket?,
        ) {
        Ok(value) => value
        Err(_) => raise CliError("invalid listener id, address, or capacity")
      }
      effective_listeners.push(config)
    }
  }
  if !allow_anonymous && password_file is None {
    raise CliError("--allow-anonymous false requires --password-file")
  }
  let startup_sources : (
    @bundle.CapturedBundle,
    @bundle.ReloadEffectiveCandidate,
    Bytes,
  )? = if reload_enabled || reload_manifest_file != "" {
    let selected_config = match config_path {
      Some(path) if path.has_prefix("/") => path
      _ => raise CliError("reload manifest requires an absolute --config path")
    }
    if !reload_manifest_file.has_prefix("/") {
      raise CliError("reload manifest path must be absolute")
    }
    let bundle = @bundle.capture_bundle(
      reload_manifest_file,
      max_source_bytes=reload_max_source_bytes,
    ) catch {
      _ => raise CliError("reload bundle capture failed")
    }
    let captured = match bundle.material_bytes("config") {
      Some(value) => value
      None => raise CliError("reload bundle lacks config")
    }
    let captured_text = @utf8.decode(captured) catch {
      _ => raise CliError("reload config must be UTF-8")
    }
    if Some(captured_text) != loaded_config_text {
      raise CliError("reload config changed during startup")
    }
    let candidate = bundle.evaluate(selected_config, cli_args) catch {
      _ => raise CliError("reload bundle does not match effective config")
    }
    let hot = candidate.hot()
    if hot.allow_anonymous != allow_anonymous ||
      hot.password_file != password_file ||
      hot.acl_file != acl_file {
      raise CliError("reload security sources differ from startup config")
    }
    let fingerprint = bundle.policy_fingerprint(candidate) catch {
      _ => raise CliError("reload policy fingerprint unavailable")
    }
    Some((bundle, candidate, fingerprint))
  } else {
    None
  }
  let security = match startup_sources {
    Some((bundle, candidate, _)) =>
      bundle.prepare_security_isolated(candidate) catch {
        _ => raise CliError("reload security validation failed")
      }
    None => {
      let passwords = match password_file {
        None => None
        Some(path) => {
          let kind = @fs.kind(path, follow_symlink=false) catch {
            _ =>
              raise CliError(
                "--password-file must name a readable regular file",
              )
          }
          if kind != @fs.Regular {
            raise CliError("--password-file must name a readable regular file")
          }
          let bytes = @fs.read_file(path) catch {
            _ => raise CliError("failed to read --password-file")
          }
          if bytes.binary().length() > 1048576 {
            raise CliError("--password-file exceeds 1048576 bytes")
          }
          let contents = bytes.text() catch {
            _ => raise CliError("--password-file must be UTF-8")
          }
          Some(
            match @security.PasswordDatabase::parse(contents) {
              Ok(value) => value
              Err(@security.PasswordFileError::Argon2Unavailable) =>
                raise CliError(
                  "Argon2id authentication requires libargon2.so.1: install libargon2-1 on Ubuntu/Debian or use the project Docker image",
                )
              Err(_) => raise CliError("invalid --password-file")
            },
          )
        }
      }
      let acl = match acl_file {
        None => None
        Some(path) => {
          let kind = @fs.kind(path, follow_symlink=false) catch {
            _ => raise CliError("--acl-file must name a readable regular file")
          }
          if kind != @fs.Regular {
            raise CliError("--acl-file must name a readable regular file")
          }
          let bytes = @fs.read_file(path) catch {
            _ => raise CliError("failed to read --acl-file")
          }
          if bytes.binary().length() > 1048576 {
            raise CliError("--acl-file exceeds 1048576 bytes")
          }
          let contents = bytes.text() catch {
            _ => raise CliError("--acl-file must be UTF-8")
          }
          Some(
            match @security.AclPolicy::parse(contents) {
              Ok(value) => value
              Err(_) => raise CliError("invalid --acl-file")
            },
          )
        }
      }
      @security.SecurityPolicy::new(allow_anonymous~, passwords?, acl?)
    }
  }
  let logger = @observability.Logger::new(
    minimum_level=log_level,
    format=log_format,
  )
  if snapshot_option_used && data_dir is None {
    raise CliError("snapshot options require --data-dir")
  }
  let effective_persistence_mode = if persistence_mode == "auto" {
    if data_dir is Some(_) {
      "snapshot"
    } else {
      "off"
    }
  } else {
    persistence_mode
  }
  if effective_persistence_mode == "off" && data_dir is Some(_) {
    raise CliError("off persistence must not specify --data-dir")
  }
  if effective_persistence_mode != "off" && data_dir is None {
    raise CliError("snapshot and strict persistence require --data-dir")
  }
  if effective_persistence_mode == "strict" && snapshot_timing_option_used {
    raise CliError("snapshot timing options do not apply to strict persistence")
  }
  if wal_option_used && effective_persistence_mode != "strict" {
    raise CliError("WAL options require strict persistence")
  }
  if wal_disk_reserve_bytes > 9223372036854775807L - 67108864L ||
    wal_disk_max_bytes < wal_disk_reserve_bytes + 67108864L {
    raise CliError("WAL disk max must exceed reserve by at least one segment")
  }
  match data_dir {
    Some(path) =>
      match
        @persistence.PersistenceConfig::new(
          path,
          max_snapshot_bytes~,
          debounce_ms=snapshot_debounce_ms,
          max_delay_ms=snapshot_max_delay_ms,
          retry_ms=snapshot_retry_ms,
        ) {
        Ok(_) => ()
        Err(error) =>
          raise CliError("persistence configuration: " + error.category())
      }
    None => ()
  }
  if check_config || print_effective_config {
    if startup_sources is Some((bundle, candidate, _)) &&
      !candidate.hot().tls_sources.is_empty() {
      if !reload_material_runtime_dir.has_prefix("/") {
        raise CliError("reload TLS requires an absolute private material root")
      }
      let state = @router.BrokerState::new(broker_config)
      let limits = broker_config.resources()
      let pool = state
        .resource_ledger()
        .pool(@budget.Infrastructure, limits.get("max_managed_bytes_total"))
        .unwrap()
      let prepared = @server.prepare_tls_generation(
        bundle, candidate, pool, reload_material_runtime_dir,
      ) catch {
        _ => raise CliError("reload TLS material validation failed")
      }
      prepared.release()
    }
  }
  if print_effective_config {
    let quote = fn(value : String) { @json.to_json(value).stringify() }
    println("[server]")
    if listener_drafts.is_empty() {
      println("listen = " + quote(listen))
    }
    println("max_connections = " + max_connections.to_string())
    println("max_packet_size = " + max_packet_size.to_string())
    println("max_receive_buffer_size = " + max_receive_buffer_size.to_string())
    println("max_outbound_queue = " + max_outbound_queue.to_string())
    println("max_runtime_events = " + max_runtime_events.to_string())
    println("connect_timeout_ms = " + connect_timeout_ms.to_string())
    println(
      "keep_alive_check_interval_ms = " +
      keep_alive_check_interval_ms.to_string(),
    )
    print_resource_section_values(resources, "server")
    println("[broker]")
    println(
      "max_subscriptions_per_session = " +
      max_subscriptions_per_session.to_string(),
    )
    println("max_subscriptions_total = " + max_subscriptions_total.to_string())
    println("max_retained_messages = " + max_retained_messages.to_string())
    println("max_sessions = " + max_sessions.to_string())
    println(
      "max_inflight_per_session = " + max_inflight_per_session.to_string(),
    )
    println("max_inflight_total = " + max_inflight_total.to_string())
    println(
      "max_pending_per_session = " + max_pending_qos1_per_session.to_string(),
    )
    println("max_pending_total = " + max_pending_qos1_total.to_string())
    println(
      "max_inbound_qos2_per_session = " +
      max_inbound_qos2_per_session.to_string(),
    )
    println("max_inbound_qos2_total = " + max_inbound_qos2_total.to_string())
    println(
      "persistent_session_expiry = " +
      quote(
        if persistent_session_expiry_ms < 0L {
          "never"
        } else {
          persistent_session_expiry_ms.to_string() + "ms"
        },
      ),
    )
    println(
      "max_session_expirations_per_tick = " +
      max_session_expirations_per_tick.to_string(),
    )
    print_resource_section_values(resources, "broker")
    println("[persistence]")
    println("mode = " + quote(effective_persistence_mode))
    println("data_dir = " + quote(data_dir.unwrap_or("")))
    println("max_snapshot_bytes = " + max_snapshot_bytes.to_string())
    println("snapshot_debounce_ms = " + snapshot_debounce_ms.to_string())
    println("snapshot_max_delay_ms = " + snapshot_max_delay_ms.to_string())
    println("snapshot_retry_ms = " + snapshot_retry_ms.to_string())
    println("wal_disk_max_bytes = " + wal_disk_max_bytes.to_string())
    println("wal_disk_reserve_bytes = " + wal_disk_reserve_bytes.to_string())
    if listener_drafts.is_empty() {
      println("[tls]")
      println("cert = " + quote(tls_certificate_file.unwrap_or("")))
      let effective_tls_key = match tls_private_key_file {
        Some(_) => "<redacted>"
        None => ""
      }
      println("key = " + quote(effective_tls_key))
      println("handshake_timeout_ms = " + tls_handshake_timeout_ms.to_string())
    }
    println("[security]")
    println("allow_anonymous = " + allow_anonymous.to_string())
    let effective_password_file = match password_file {
      Some(_) => "<redacted>"
      None => ""
    }
    println("password_file = " + quote(effective_password_file))
    println("acl_file = " + quote(acl_file.unwrap_or("")))
    println("auth_workers = " + auth_workers.to_string())
    println("auth_queue_limit = " + auth_queue_limit.to_string())
    println("auth_timeout_ms = " + auth_timeout_ms.to_string())
    println("auth_poll_interval_ms = " + auth_poll_interval_ms.to_string())
    println("auth_result_batch_limit = " + auth_result_batch_limit.to_string())
    println("auth_shutdown_grace_ms = " + auth_shutdown_grace_ms.to_string())
    println("[observability]")
    println(
      "system_metrics_interval_ms = " + system_metrics_interval_ms.to_string(),
    )
    let effective_log_format = match log_format {
      @observability.Text => "text"
      @observability.Json => "json"
    }
    let effective_log_level = match log_level {
      @observability.Error => "error"
      @observability.Warn => "warn"
      @observability.Info => "info"
      @observability.Debug => "debug"
    }
    println("log_format = " + quote(effective_log_format))
    println("log_level = " + quote(effective_log_level))
    println("[management]")
    println("enabled = " + management_enabled.to_string())
    println("listen = " + quote(management_listen))
    println(
      "token_file = " +
      quote(if management_token_file == "" { "" } else { "<redacted>" }),
    )
    println("max_connections = " + management_max_connections.to_string())
    println("max_header_bytes = " + management_max_header_bytes.to_string())
    println("max_header_count = " + management_max_header_count.to_string())
    println("max_response_bytes = " + management_max_response_bytes.to_string())
    println("request_timeout_ms = " + management_request_timeout_ms.to_string())
    println("write_timeout_ms = " + management_write_timeout_ms.to_string())
    println(
      "snapshot_interval_ms = " + management_snapshot_interval_ms.to_string(),
    )
    println(
      "snapshot_max_age_ms = " + management_snapshot_max_age_ms.to_string(),
    )
    println(
      "ready_require_snapshot_healthy = " +
      management_ready_require_snapshot_healthy.to_string(),
    )
    println("request_rate = " + management_request_rate.to_string())
    println("request_burst = " + management_request_burst.to_string())
    println("connection_rate = " + management_connection_rate.to_string())
    println("connection_burst = " + management_connection_burst.to_string())
    println("details_enabled = " + management_details_enabled.to_string())
    println("operations_enabled = " + management_operations_enabled.to_string())
    println("query_queue_limit = " + management_query_queue_limit.to_string())
    println(
      "operation_queue_limit = " + management_operation_queue_limit.to_string(),
    )
    println(
      "max_operation_records = " + management_max_operation_records.to_string(),
    )
    println(
      "max_running_operations = " +
      management_max_running_operations.to_string(),
    )
    println(
      "operation_timeout_ms = " + management_operation_timeout_ms.to_string(),
    )
    println(
      "operation_retention_ms = " +
      management_operation_retention_ms.to_string(),
    )
    println("max_cursor_records = " + management_max_cursor_records.to_string())
    println("cursor_ttl_ms = " + management_cursor_ttl_ms.to_string())
    println("default_page_size = " + management_default_page_size.to_string())
    println("max_page_size = " + management_max_page_size.to_string())
    println("query_scan_limit = " + management_query_scan_limit.to_string())
    println("query_timeout_ms = " + management_query_timeout_ms.to_string())
    println("max_audit_records = " + management_max_audit_records.to_string())
    println("command_rate = " + management_command_rate.to_string())
    println("command_burst = " + management_command_burst.to_string())
    println("max_index_bytes = " + management_max_index_bytes.to_string())
    println("max_bytes_total = " + management_max_bytes_total.to_string())
    println("[reload]")
    println("enabled = " + reload_enabled.to_string())
    println(
      "manifest_file = " +
      quote(if reload_manifest_file == "" { "" } else { "<redacted>" }),
    )
    println("material_runtime_dir = " + quote(reload_material_runtime_dir))
    println("prepare_timeout_ms = " + reload_prepare_timeout_ms.to_string())
    println("max_source_bytes = " + reload_max_source_bytes.to_string())
    println("max_generation_bytes = " + reload_max_generation_bytes.to_string())
    println(
      "max_reconcile_items_per_turn = " +
      reload_max_reconcile_items_per_turn.to_string(),
    )
    println(
      "max_reconcile_bytes_per_turn = " +
      reload_max_reconcile_bytes_per_turn.to_string(),
    )
    println("max_accounts = " + reload_max_accounts.to_string())
    println("max_acl_rules = " + reload_max_acl_rules.to_string())
    println("[resources]")
    print_resource_section_values(resources, "resources")
    println("[limits]")
    println("enabled = " + resources.rates_enabled().to_string())
    println("per_ip_enabled = " + resources.per_ip_enabled().to_string())
    print_resource_section_values(resources, "limits")
    if !listener_drafts.is_empty() {
      for draft in listener_drafts {
        println("[[listeners]]")
        println("id = " + quote(draft.id))
        println("transport = " + quote(draft.transport))
        println("listen = " + quote(draft.listen))
        let cap = if draft.max_connections < 0 {
          max_connections
        } else {
          draft.max_connections
        }
        println("max_connections = " + cap.to_string())
        if draft.transport == "tls" || draft.transport == "wss" {
          println("tls_cert = " + quote(draft.cert))
          println("tls_key = " + quote("<redacted>"))
          println(
            "tls_handshake_timeout_ms = " +
            draft.handshake_timeout_ms.to_string(),
          )
        }
        if draft.transport == "ws" || draft.transport == "wss" {
          println("ws_path = " + quote(draft.ws_path))
          let origins : Array[String] = []
          for origin in draft.ws_allowed_origins {
            origins.push(quote(origin))
          }
          println("ws_allowed_origins = [" + origins.join(", ") + "]")
          println("ws_require_origin = " + draft.ws_require_origin.to_string())
          println(
            "http_upgrade_timeout_ms = " +
            draft.http_upgrade_timeout_ms.to_string(),
          )
          println(
            "max_http_header_bytes = " + draft.max_http_header_bytes.to_string(),
          )
          println(
            "max_ws_frame_bytes = " + draft.max_ws_frame_bytes.to_string(),
          )
          println(
            "max_ws_message_bytes = " + draft.max_ws_message_bytes.to_string(),
          )
        }
      }
    }
    return
  }
  if reload_enabled {
    if config_path is None ||
      reload_manifest_file == "" ||
      !reload_manifest_file.has_prefix("/") {
      raise CliError("reload requires --config and an absolute manifest path")
    }
    if !config_path.unwrap().has_prefix("/") {
      raise CliError("reload requires an absolute --config path")
    }
    if effective_listeners.any(listener => listener.tls is Some(_)) &&
      !reload_material_runtime_dir.has_prefix("/") {
      raise CliError("reload TLS requires an absolute private material root")
    }
    if reload_prepare_timeout_ms > 300000 ||
      reload_max_source_bytes > 67108864 ||
      reload_max_generation_bytes > 268435456L ||
      reload_max_reconcile_items_per_turn > 256 ||
      reload_max_reconcile_bytes_per_turn > 4194304 ||
      reload_max_accounts > 4096 ||
      reload_max_acl_rules > 4096 {
      raise CliError("reload resource limit exceeds supported range")
    }
  }
  if check_config {
    println("configuration valid")
    return
  }
  if reload_enabled {
    raise CliError("reload coordinator is not yet available")
  }
  let reload_tls : (
    @bundle.CapturedBundle,
    @bundle.ReloadEffectiveCandidate,
    String,
  )? = match startup_sources {
    Some((bundle, candidate, _)) => {
      if !candidate.hot().tls_sources.is_empty() &&
        !reload_material_runtime_dir.has_prefix("/") {
        raise CliError("reload TLS requires an absolute private material root")
      }
      Some((bundle, candidate, reload_material_runtime_dir))
    }
    None => None
  }
  let management : @server.ManagementStartup? = management_tokens.map(tokens => {
    config: management_config,
    tokens,
  })
  match data_dir {
    None => {
      let initial_state = @router.BrokerState::new(broker_config)
      if startup_sources is Some(_) {
        @server.bootstrap_runtime_policy(
          initial_state,
          security,
          1L,
          reload_max_reconcile_items_per_turn,
          reload_max_reconcile_bytes_per_turn.to_int64(),
        )
      }
      @server.run_listeners(
        effective_listeners,
        config,
        initial_state,
        shutdown_requested~,
        once~,
        security~,
        logger~,
        management?,
        reload_tls?,
        reload_enabled~,
      )
    }
    Some(path) => {
      let persistence_config = match
        @persistence.PersistenceConfig::new(
          path,
          max_snapshot_bytes~,
          debounce_ms=snapshot_debounce_ms,
          max_delay_ms=snapshot_max_delay_ms,
          retry_ms=snapshot_retry_ms,
        ) {
        Ok(value) => value
        Err(error) =>
          raise CliError("persistence configuration: " + error.category())
      }
      let store = match @persistence.SnapshotStore::open(persistence_config) {
        Ok(value) => value
        Err(error) => raise CliError("persistence startup: " + error.category())
      }
      let manifest_path = store.data_dir() + "/broker.manifest"
      let has_manifest = @fs.exists(manifest_path) catch {
        _ => {
          store.close()
          raise CliError("cannot inspect persistence manifest")
        }
      }
      if effective_persistence_mode == "snapshot" && has_manifest {
        store.close()
        raise CliError("strict WAL directory cannot start in snapshot mode")
      }
      if effective_persistence_mode == "strict" {
        let limits = match
          @persistence.SnapshotDecodeLimits::new(
            broker_config,
            config.max_packet_size(),
            max_snapshot_bytes=max_snapshot_bytes.to_int(),
          ) {
          Ok(value) => value
          Err(error) => {
            store.close()
            raise CliError("strict decode limits: " + error.category())
          }
        }
        let (wal_store, initial_state, identities, committed_lsn) = if has_manifest {
          let (wal_store, restored) = match
            @persistence.WalStore::recover_state(
              store,
              broker_config,
              limits,
              disk_max_bytes=wal_disk_max_bytes,
              disk_reserve_bytes=wal_disk_reserve_bytes,
            ) {
            Ok(value) => value
            Err(error) => {
              store.close()
              raise CliError("WAL recovery: " + error.category())
            }
          }
          (
            wal_store,
            restored.state(),
            restored.identities(),
            restored.committed_lsn(),
          )
        } else {
          let initial_state = match
            store.load_state(broker_config, config.max_packet_size()) {
            Ok(value) => value
            Err(error) => {
              store.close()
              raise CliError("snapshot import: " + error.category())
            }
          }
          let snapshot = initial_state.export_snapshot()
          let identities : Array[@persistence.WalSessionIdentity] = []
          for index in 0..<snapshot.sessions.length() {
            identities.push({
              client_id: snapshot.sessions[index].client_id,
              generation: index.to_int64() + 1L,
            })
          }
          let wal_store = match
            @persistence.WalStore::bootstrap(
              store,
              { generation: 1L, lsn: 0L, identities, policy: None, snapshot },
              disk_max_bytes=wal_disk_max_bytes,
              disk_reserve_bytes=wal_disk_reserve_bytes,
            ) {
            Ok(value) => value
            Err(error) => {
              store.close()
              raise CliError("WAL bootstrap: " + error.category())
            }
          }
          (wal_store, initial_state, identities, 0L)
        }
        let (identities, committed_lsn) = if wal_store.manifest().policy_required ||
          reload_enabled {
          let fingerprint = match startup_sources {
            Some((_, _, value)) => value
            None => {
              wal_store.close()
              raise CliError(
                "strict policy source requires a matching reload bundle",
              )
            }
          }
          let boot = @server.bootstrap_strict_policy(
            wal_store,
            initial_state,
            identities,
            security,
            fingerprint,
            reload_max_reconcile_items_per_turn,
            reload_max_reconcile_bytes_per_turn.to_int64(),
          ) catch {
            error => {
              wal_store.close()
              raise CliError("strict policy startup: " + error.to_string())
            }
          }
          (boot.identities, boot.committed_lsn)
        } else {
          (identities, committed_lsn)
        }
        let strict = match
          @server.StrictPersistenceRuntime::new(
            wal_store, initial_state, identities, committed_lsn,
          ) {
          Ok(value) => value
          Err(error) => {
            wal_store.close()
            raise CliError("strict runtime: " + error.category())
          }
        }
        logger.log(
          @observability.LogRecord::new(
            @async.now(),
            @observability.Info,
            "wal_restored",
            message="strict WAL restored committed_lsn=" +
              committed_lsn.to_string(),
          ),
        )
        @server.run_listeners(
          effective_listeners,
          config,
          initial_state,
          strict~,
          shutdown_requested~,
          once~,
          security~,
          logger~,
          management?,
          reload_tls?,
          reload_enabled~,
        )
        return
      }
      let initial_state = match
        store.load_state(broker_config, config.max_packet_size()) {
        Ok(value) => value
        Err(error) => {
          store.close()
          raise CliError("snapshot recovery: " + error.category())
        }
      }
      if startup_sources is Some(_) {
        @server.bootstrap_runtime_policy(
          initial_state,
          security,
          1L,
          reload_max_reconcile_items_per_turn,
          reload_max_reconcile_bytes_per_turn.to_int64(),
        ) catch {
          error => {
            store.close()
            raise CliError("snapshot policy startup: " + error.to_string())
          }
        }
      }
      let snapshot_bytes = match store.snapshot_size() {
        Ok(Some(value)) => value
        Ok(None) => 0L
        Err(error) => {
          store.close()
          raise CliError("snapshot metadata: " + error.category())
        }
      }
      let persistence = match
        @server.PersistenceRuntime::new(store, persistence_config, logger~) {
        Ok(value) => value
        Err(error) => {
          store.close()
          raise CliError("persistence runtime: " + error.category())
        }
      }
      logger.log(
        @observability.LogRecord::new(
          @async.now(),
          @observability.Info,
          "snapshot_restored",
          message="snapshot restored version=1-or-2-or-3 sessions=" +
            initial_state.session_count().to_string() +
            " retained=" +
            initial_state.retained_count().to_string() +
            " bytes=" +
            snapshot_bytes.to_string() +
            " data_dir=" +
            store.data_dir(),
          snapshot_revision=initial_state.snapshot_revision().to_string(),
        ),
      )
      @server.run_listeners(
        effective_listeners,
        config,
        initial_state,
        persistence~,
        shutdown_requested~,
        once~,
        security~,
        logger~,
        management?,
        reload_tls?,
        reload_enabled~,
      )
    }
  }
}

///|
async fn main {
  run_main() catch {
    CliError(message) as error => {
      println("broker: " + message)
      raise error
    }
    error => raise error
  }
}

///|
fn print_resource_section_values(
  limits : @budget.Limits,
  section : String,
) -> Unit {
  let specs = @budget.byte_limit_specs()
  specs.append(@budget.rate_limit_specs())
  for spec in specs {
    let (owner, key, _) = spec
    if owner == section {
      println(key + " = " + limits.get(key).to_string())
    }
  }
}
