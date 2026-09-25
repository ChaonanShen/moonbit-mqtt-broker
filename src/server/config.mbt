///|
pub struct ServerConfig {
  max_connections : Int
  max_packet_size : Int
  max_receive_buffer_size : Int
  max_outbound_queue : Int
  max_runtime_events : Int
  connect_timeout_ms : Int
  keep_alive_check_interval_ms : Int
  system_metrics_interval_ms : Int
  auth_workers : Int
  auth_queue_limit : Int
  auth_timeout_ms : Int
  auth_poll_interval_ms : Int
  auth_result_batch_limit : Int
  auth_shutdown_grace_ms : Int
  broker_config : @router.BrokerConfig
  protocol_config : @config.ProtocolConfig
} derive(Eq, Debug)

///|
pub fn ServerConfig::new(
  max_connections : Int,
  max_packet_size : Int,
  max_receive_buffer_size : Int,
  max_outbound_queue : Int,
  max_runtime_events : Int,
  connect_timeout_ms : Int,
  keep_alive_check_interval_ms : Int,
  broker_config : @router.BrokerConfig,
  system_metrics_interval_ms? : Int = 10000,
  auth_workers? : Int = 1,
  auth_queue_limit? : Int = 16,
  auth_timeout_ms? : Int = 10000,
  auth_poll_interval_ms? : Int = 1,
  auth_result_batch_limit? : Int = 16,
  auth_shutdown_grace_ms? : Int = 10000,
  protocol_config? : @config.ProtocolConfig = @config.ProtocolConfig::new().unwrap(),
) -> Result[ServerConfig, ServerError] {
  if max_connections < 1 {
    return Err(InvalidConfiguration("max_connections must be at least 1"))
  }
  if max_packet_size < 2 {
    return Err(InvalidConfiguration("max_packet_size must be at least 2"))
  }
  if max_receive_buffer_size < max_packet_size {
    return Err(
      InvalidConfiguration(
        "max_receive_buffer_size must be at least max_packet_size",
      ),
    )
  }
  if max_outbound_queue < 1 {
    return Err(InvalidConfiguration("max_outbound_queue must be at least 1"))
  }
  if max_runtime_events < 1 {
    return Err(InvalidConfiguration("max_runtime_events must be at least 1"))
  }
  if connect_timeout_ms < 1 {
    return Err(InvalidConfiguration("connect_timeout_ms must be at least 1"))
  }
  if keep_alive_check_interval_ms < 1 ||
    keep_alive_check_interval_ms > connect_timeout_ms {
    return Err(
      InvalidConfiguration(
        "keep_alive_check_interval_ms must be in 1..connect_timeout_ms",
      ),
    )
  }
  if system_metrics_interval_ms < 1 {
    return Err(
      InvalidConfiguration("system_metrics_interval_ms must be at least 1"),
    )
  }
  if auth_workers < 1 || auth_workers > 64 {
    return Err(InvalidConfiguration("auth_workers must be in 1..64"))
  }
  if auth_queue_limit < 0 || auth_queue_limit > 4096 - auth_workers {
    return Err(
      InvalidConfiguration("auth_queue_limit exceeds executor capacity"),
    )
  }
  if auth_timeout_ms < 1 {
    return Err(InvalidConfiguration("auth_timeout_ms must be at least 1"))
  }
  if auth_poll_interval_ms < 1 || auth_poll_interval_ms > connect_timeout_ms {
    return Err(
      InvalidConfiguration(
        "auth_poll_interval_ms must be in 1..connect_timeout_ms",
      ),
    )
  }
  if auth_result_batch_limit < 1 ||
    auth_result_batch_limit > auth_workers + auth_queue_limit {
    return Err(
      InvalidConfiguration("auth_result_batch_limit exceeds executor capacity"),
    )
  }
  if auth_shutdown_grace_ms < 1 {
    return Err(
      InvalidConfiguration("auth_shutdown_grace_ms must be at least 1"),
    )
  }
  if protocol_config.mqtt5_enabled {
    if protocol_config.max_property_bytes > max_packet_size {
      return Err(
        InvalidConfiguration("max_property_bytes exceeds max_packet_size"),
      )
    }
    if protocol_config.server_receive_maximum >
      broker_config.max_inbound_qos2_per_session() {
      return Err(
        InvalidConfiguration(
          "server_receive_maximum exceeds inbound QoS2 limit",
        ),
      )
    }
    if protocol_config.max_delayed_wills >
      broker_config.max_sessions() + max_connections {
      return Err(
        InvalidConfiguration(
          "max_delayed_wills exceeds session and connection capacity",
        ),
      )
    }
    if protocol_config.mqtt5_enabled &&
      broker_config.max_inflight_per_session() < 1 {
      return Err(
        InvalidConfiguration("MQTT 5 requires outbound inflight capacity"),
      )
    }
  }
  let resources = broker_config.resources()
  let fixed_control = max_connections.to_int64() * 512L + 256L
  let fixed_data = max_runtime_events.to_int64() * 64L + 17408L
  if resources.get("control_reserve_bytes") < fixed_control ||
    resources.get("max_managed_bytes_total") -
    resources.get("control_reserve_bytes") <
    fixed_data {
    return Err(
      InvalidConfiguration(
        "resource budget cannot fit fixed control/data infrastructure",
      ),
    )
  }
  if resources.get("max_outbound_bytes_per_connection") < 4L ||
    resources.get("max_outbound_bytes_total") < 4L {
    return Err(InvalidConfiguration("outbound budget must fit CONNACK"))
  }
  Ok({
    max_connections,
    max_packet_size,
    max_receive_buffer_size,
    max_outbound_queue,
    max_runtime_events,
    connect_timeout_ms,
    keep_alive_check_interval_ms,
    system_metrics_interval_ms,
    auth_workers,
    auth_queue_limit,
    auth_timeout_ms,
    auth_poll_interval_ms,
    auth_result_batch_limit,
    auth_shutdown_grace_ms,
    broker_config,
    protocol_config,
  })
}

///|
pub fn ServerConfig::default() -> ServerConfig {
  let broker_config = @router.BrokerConfig::new(128, 16384, 1024).unwrap()
  ServerConfig::new(
    128,
    1048576,
    1048576,
    64,
    512,
    10000,
    100,
    broker_config,
    auth_poll_interval_ms=5,
  ).unwrap()
}

///|
pub fn ServerConfig::max_connections(self : ServerConfig) -> Int {
  self.max_connections
}

///|
pub fn ServerConfig::max_packet_size(self : ServerConfig) -> Int {
  self.max_packet_size
}

///|
pub fn ServerConfig::max_receive_buffer_size(self : ServerConfig) -> Int {
  self.max_receive_buffer_size
}

///|
pub fn ServerConfig::max_outbound_queue(self : ServerConfig) -> Int {
  self.max_outbound_queue
}

///|
pub fn ServerConfig::max_runtime_events(self : ServerConfig) -> Int {
  self.max_runtime_events
}

///|
pub fn ServerConfig::connect_timeout_ms(self : ServerConfig) -> Int {
  self.connect_timeout_ms
}

///|
pub fn ServerConfig::keep_alive_check_interval_ms(self : ServerConfig) -> Int {
  self.keep_alive_check_interval_ms
}

///|
pub fn ServerConfig::system_metrics_interval_ms(self : ServerConfig) -> Int {
  self.system_metrics_interval_ms
}

///|
pub fn ServerConfig::auth_workers(self : ServerConfig) -> Int {
  self.auth_workers
}

///|
pub fn ServerConfig::auth_queue_limit(self : ServerConfig) -> Int {
  self.auth_queue_limit
}

///|
pub fn ServerConfig::auth_timeout_ms(self : ServerConfig) -> Int {
  self.auth_timeout_ms
}

///|
pub fn ServerConfig::auth_poll_interval_ms(self : ServerConfig) -> Int {
  self.auth_poll_interval_ms
}

///|
pub fn ServerConfig::auth_result_batch_limit(self : ServerConfig) -> Int {
  self.auth_result_batch_limit
}

///|
pub fn ServerConfig::auth_shutdown_grace_ms(self : ServerConfig) -> Int {
  self.auth_shutdown_grace_ms
}

///|
pub fn ServerConfig::broker_config(self : ServerConfig) -> @router.BrokerConfig {
  self.broker_config
}

///|
pub fn ServerConfig::protocol_config(
  self : ServerConfig,
) -> @config.ProtocolConfig {
  self.protocol_config
}
