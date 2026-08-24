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
  println("MQTT 3.1.1 QoS 0/1 Broker for Linux x86_64 Native.")
  println("The supported environment is the pinned Ubuntu 24.04 Docker image.")
  println("")
  println("Options:")
  println(
    "  -h, --help                         Show this help without starting the Broker",
  )
  println("  --version                          Show the release version")
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
  println("  --max-subscriptions-per-session N  Default 128")
  println("  --max-subscriptions-total N        Default 16384")
  println("  --max-retained-messages N          Default 1024")
  println("  --max-sessions N                   Default 1024")
  println("  --max-inflight-per-session N       Default 16")
  println("  --max-inflight-total N             Default 512")
  println("  --max-pending-qos1-per-session N   Default 64")
  println("  --max-pending-qos1-total N         Default 1024")
  println("  --data-dir PATH                    Enable Disk V1 snapshots")
  println("  --max-snapshot-bytes N             Default 67108864")
  println("  --snapshot-debounce-ms N           Default 250")
  println("  --snapshot-max-delay-ms N          Default 2000")
  println("  --snapshot-retry-ms N              Default 1000")
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
async fn run_main() -> Unit {
  let args = @env.args()
  let mut listen = "127.0.0.1:1883"
  let mut max_connections = 128
  let mut max_packet_size = 1048576
  let mut max_receive_buffer_size = 1048576
  let mut max_outbound_queue = 64
  let mut max_runtime_events = 512
  let mut connect_timeout_ms = 10000
  let mut keep_alive_check_interval_ms = 100
  let mut max_subscriptions_per_session = 128
  let mut max_subscriptions_total = 16384
  let mut max_retained_messages = 1024
  let mut max_sessions = 1024
  let mut max_inflight_per_session = 16
  let mut max_inflight_total = 512
  let mut max_pending_qos1_per_session = 64
  let mut max_pending_qos1_total = 1024
  let mut data_dir : String? = None
  let mut max_snapshot_bytes = 67108864L
  let mut snapshot_debounce_ms = 250L
  let mut snapshot_max_delay_ms = 2000L
  let mut snapshot_retry_ms = 1000L
  let mut snapshot_option_used = false
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
      "--max-pending-qos1-per-session" => {
        max_pending_qos1_per_session = parse_bounded_int(
          args, index, "--max-pending-qos1-per-session", 0,
        )
        index = index + 2
      }
      "--max-pending-qos1-total" => {
        max_pending_qos1_total = parse_bounded_int(
          args, index, "--max-pending-qos1-total", 0,
        )
        index = index + 2
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
      "--once" => {
        once = true
        index = index + 1
      }
      value => raise CliError("unknown argument: " + value)
    }
  }
  let broker_config = match
    @router.BrokerConfig::new(
      max_subscriptions_per_session,
      max_subscriptions_total,
      max_retained_messages,
      max_sessions~,
      max_inflight_per_session~,
      max_inflight_total~,
      max_pending_qos1_per_session~,
      max_pending_qos1_total~,
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
      max_connections, max_packet_size, max_receive_buffer_size, max_outbound_queue,
      max_runtime_events, connect_timeout_ms, keep_alive_check_interval_ms, broker_config,
    ) {
    Ok(value) => value
    Err(_) => raise CliError("invalid server configuration")
  }
  match data_dir {
    None => {
      if snapshot_option_used {
        raise CliError("snapshot options require --data-dir")
      }
      @server.run(
        listen,
        config,
        @router.BrokerState::new(broker_config),
        once~,
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
        @server.PersistenceRuntime::new(store, persistence_config) {
        Ok(value) => value
        Err(error) => {
          store.close()
          raise CliError("persistence runtime: " + error.category())
        }
      }
      println(
        "snapshot restored version=1 sessions=" +
        initial_state.session_count().to_string() +
        " retained=" +
        initial_state.retained_count().to_string() +
        " bytes=" +
        snapshot_bytes.to_string() +
        " data_dir=" +
        store.data_dir(),
      )
      @server.run(listen, config, initial_state, persistence~, once~)
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
