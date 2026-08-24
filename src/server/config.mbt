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
  broker_config : @router.BrokerConfig
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
  Ok({
    max_connections,
    max_packet_size,
    max_receive_buffer_size,
    max_outbound_queue,
    max_runtime_events,
    connect_timeout_ms,
    keep_alive_check_interval_ms,
    system_metrics_interval_ms,
    broker_config,
  })
}

///|
pub fn ServerConfig::default() -> ServerConfig {
  let broker_config = @router.BrokerConfig::new(128, 16384, 1024).unwrap()
  ServerConfig::new(128, 1048576, 1048576, 64, 512, 10000, 100, broker_config).unwrap()
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
pub fn ServerConfig::broker_config(self : ServerConfig) -> @router.BrokerConfig {
  self.broker_config
}
