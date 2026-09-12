///|
suberror CliError {
  CliError(String)
} derive(Debug)

///|
const RELEASE_VERSION : String = "0.1.0"

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
  println("  --data-dir PATH                    Enable Disk V3 snapshots")
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
        index = index + 2
      }
      "--snapshot-max-delay-ms" => {
        snapshot_max_delay_ms = parse_bounded_int64(
          args, index, "--snapshot-max-delay-ms", 1L,
        )
        snapshot_option_used = true
        index = index + 2
      }
      "--snapshot-retry-ms" => {
        snapshot_retry_ms = parse_bounded_int64(
          args, index, "--snapshot-retry-ms", 1L,
        )
        snapshot_option_used = true
        index = index + 2
      }
      "--tls-cert" => {
        if index + 1 >= args.length() || args[index + 1] == "" {
          raise CliError("--tls-cert requires a non-empty path")
        }
        tls_certificate_file = Some(args[index + 1])
        index = index + 2
      }
      "--tls-key" => {
        if index + 1 >= args.length() || args[index + 1] == "" {
          raise CliError("--tls-key requires a non-empty path")
        }
        tls_private_key_file = Some(args[index + 1])
        index = index + 2
      }
      "--tls-handshake-timeout-ms" => {
        tls_handshake_timeout_ms = parse_bounded_int(
          args, index, "--tls-handshake-timeout-ms", 1,
        )
        tls_timeout_option_used = true
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
      let value = @server.TlsServerConfig::new(
        certificate_file,
        private_key_file,
        handshake_timeout_ms=tls_handshake_timeout_ms,
      ).unwrap()
      @server.validate_tls_config(value) catch {
        _ => raise CliError("TLS certificate/private key validation failed")
      }
      Some(value)
    }
    (Some(_), None) => raise CliError("--tls-cert requires --tls-key")
    (None, Some(_)) => raise CliError("--tls-key requires --tls-cert")
  }
  if !allow_anonymous && password_file is None {
    raise CliError("--allow-anonymous false requires --password-file")
  }
  let passwords = match password_file {
    None => None
    Some(path) => {
      let kind = @fs.kind(path, follow_symlink=false) catch {
        _ => raise CliError("--password-file must name a readable regular file")
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
  let security = @security.SecurityPolicy::new(
    allow_anonymous~,
    passwords?,
    acl?,
  )
  let logger = @observability.Logger::new(
    minimum_level=log_level,
    format=log_format,
  )
  if snapshot_option_used && data_dir is None {
    raise CliError("snapshot options require --data-dir")
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
  if print_effective_config {
    let quote = fn(value : String) { @json.to_json(value).stringify() }
    println("[server]")
    println("listen = " + quote(listen))
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
    println("data_dir = " + quote(data_dir.unwrap_or("")))
    println("max_snapshot_bytes = " + max_snapshot_bytes.to_string())
    println("snapshot_debounce_ms = " + snapshot_debounce_ms.to_string())
    println("snapshot_max_delay_ms = " + snapshot_max_delay_ms.to_string())
    println("snapshot_retry_ms = " + snapshot_retry_ms.to_string())
    println("[tls]")
    println("cert = " + quote(tls_certificate_file.unwrap_or("")))
    let effective_tls_key = match tls_private_key_file {
      Some(_) => "<redacted>"
      None => ""
    }
    println("key = " + quote(effective_tls_key))
    println("handshake_timeout_ms = " + tls_handshake_timeout_ms.to_string())
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
    println("[resources]")
    print_resource_section_values(resources, "resources")
    println("[limits]")
    println("enabled = " + resources.rates_enabled().to_string())
    println("per_ip_enabled = " + resources.per_ip_enabled().to_string())
    print_resource_section_values(resources, "limits")
    return
  }
  if check_config {
    println("configuration valid")
    return
  }
  match data_dir {
    None =>
      @server.run(
        listen,
        config,
        @router.BrokerState::new(broker_config),
        shutdown_requested~,
        once~,
        tls?,
        security~,
        logger~,
      )
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
      let initial_state = match
        store.load_state(broker_config, config.max_packet_size()) {
        Ok(value) => value
        Err(error) => {
          store.close()
          raise CliError("snapshot recovery: " + error.category())
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
      @server.run(
        listen,
        config,
        initial_state,
        persistence~,
        shutdown_requested~,
        once~,
        tls?,
        security~,
        logger~,
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
