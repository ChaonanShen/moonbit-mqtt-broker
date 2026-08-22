///|
suberror CliError {
  CliError(String)
} derive(Debug)

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
async fn main {
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
  let mut once = false
  let mut index = 1
  while index < args.length() {
    match args[index] {
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
  @server.run(listen, config, @router.BrokerState::new(broker_config), once~)
}
