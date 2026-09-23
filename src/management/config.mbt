///|
pub(all) suberror ManagementConfigError {
  Invalid(String)
} derive(Eq, Debug)

///|
/// Frozen startup settings for the optional loopback management listener.
/// Secrets are loaded separately; this value contains only a token file path.
pub struct ManagementConfig {
  enabled : Bool
  listen : String
  token_file : String
  max_connections : Int
  max_header_bytes : Int
  max_header_count : Int
  max_response_bytes : Int
  request_timeout_ms : Int
  write_timeout_ms : Int
  snapshot_interval_ms : Int
  snapshot_max_age_ms : Int
  ready_require_snapshot_healthy : Bool
  request_rate : Int
  request_burst : Int
  connection_rate : Int
  connection_burst : Int
  max_bytes_total : Int64
}

///|
fn valid_management_listen(value : String) -> Bool {
  if !value.has_prefix("127.0.0.1:") {
    return false
  }
  let port = value[10:].to_owned()
  if port.is_empty() || port.length() > 5 {
    return false
  }
  for digit in port {
    if digit.to_int() < 48 || digit.to_int() > 57 {
      return false
    }
  }
  if port.length() > 1 && port[0] == '0' {
    return false
  }
  let number = @string.parse_int(port) catch { _ => return false }
  number >= 1 && number <= 65535
}

///|
pub fn ManagementConfig::new(
  enabled? : Bool = false,
  listen? : String = "127.0.0.1:9091",
  token_file? : String = "",
  max_connections? : Int = 16,
  max_header_bytes? : Int = 4096,
  max_header_count? : Int = 32,
  max_response_bytes? : Int = 65536,
  request_timeout_ms? : Int = 5000,
  write_timeout_ms? : Int = 2000,
  snapshot_interval_ms? : Int = 1000,
  snapshot_max_age_ms? : Int = 5000,
  ready_require_snapshot_healthy? : Bool = false,
  request_rate? : Int = 50,
  request_burst? : Int = 100,
  connection_rate? : Int = 100,
  connection_burst? : Int = 200,
  max_bytes_total? : Int64 = 8388608L,
) -> Result[ManagementConfig, ManagementConfigError] {
  if !valid_management_listen(listen) {
    return Err(Invalid("listen"))
  }
  if max_connections < 1 || max_connections > 64 {
    return Err(Invalid("max_connections"))
  }
  if max_header_bytes < 1024 || max_header_bytes > 16384 {
    return Err(Invalid("max_header_bytes"))
  }
  if max_header_count < 1 || max_header_count > 64 {
    return Err(Invalid("max_header_count"))
  }
  if max_response_bytes < 4096 || max_response_bytes > 262144 {
    return Err(Invalid("max_response_bytes"))
  }
  if request_timeout_ms < 100 || request_timeout_ms > 30000 {
    return Err(Invalid("request_timeout_ms"))
  }
  if write_timeout_ms < 100 || write_timeout_ms > 30000 {
    return Err(Invalid("write_timeout_ms"))
  }
  if snapshot_interval_ms < 100 || snapshot_interval_ms > 10000 {
    return Err(Invalid("snapshot_interval_ms"))
  }
  if snapshot_max_age_ms < 300 || snapshot_max_age_ms > 60000 {
    return Err(Invalid("snapshot_max_age_ms"))
  }
  if request_rate < 1 || request_rate > 10000 {
    return Err(Invalid("request_rate"))
  }
  if request_burst < 1 || request_burst > 20000 {
    return Err(Invalid("request_burst"))
  }
  if connection_rate < 1 || connection_rate > 10000 {
    return Err(Invalid("connection_rate"))
  }
  if connection_burst < 1 || connection_burst > 20000 {
    return Err(Invalid("connection_burst"))
  }
  if write_timeout_ms > request_timeout_ms {
    return Err(Invalid("write_timeout_ms"))
  }
  if snapshot_max_age_ms < 3 * snapshot_interval_ms {
    return Err(Invalid("snapshot_max_age_ms"))
  }
  if token_file.length() > 4096 || (enabled && token_file == "") {
    return Err(Invalid("token_file"))
  }
  if max_bytes_total < 1L {
    return Err(Invalid("max_bytes_total"))
  }
  let config : ManagementConfig = {
    enabled,
    listen,
    token_file,
    max_connections,
    max_header_bytes,
    max_header_count,
    max_response_bytes,
    request_timeout_ms,
    write_timeout_ms,
    snapshot_interval_ms,
    snapshot_max_age_ms,
    ready_require_snapshot_healthy,
    request_rate,
    request_burst,
    connection_rate,
    connection_burst,
    max_bytes_total,
  }
  if enabled && config.required_bytes() > max_bytes_total {
    return Err(Invalid("max_bytes_total"))
  }
  Ok(config)
}

///|
pub fn ManagementConfig::default() -> ManagementConfig {
  ManagementConfig::new().unwrap()
}

///|
/// Logical parent reservation, including one reader-owned response per slot.
/// Exact allocations and release rules are implemented in A05.
pub fn ManagementConfig::required_bytes(self : ManagementConfig) -> Int64 {
  let sockets = self.max_connections.to_int64()
  let header = self.max_header_bytes.to_int64()
  let response = self.max_response_bytes.to_int64()
  let infrastructure = 65536L + 512L * sockets + 1024L * 32L
  let request_slot = 1024L + 8L * header + 4L * response
  let cache = 2L * (1024L + 8L * response)
  infrastructure + sockets * request_slot + cache
}

///|
pub fn ManagementConfig::enabled(self : ManagementConfig) -> Bool {
  self.enabled
}

///|
pub fn ManagementConfig::listen(self : ManagementConfig) -> String {
  self.listen
}

///|
pub fn ManagementConfig::token_file(self : ManagementConfig) -> String {
  self.token_file
}

///|
pub fn ManagementConfig::max_connections(self : ManagementConfig) -> Int {
  self.max_connections
}

///|
pub fn ManagementConfig::max_header_bytes(self : ManagementConfig) -> Int {
  self.max_header_bytes
}

///|
pub fn ManagementConfig::max_header_count(self : ManagementConfig) -> Int {
  self.max_header_count
}

///|
pub fn ManagementConfig::max_response_bytes(self : ManagementConfig) -> Int {
  self.max_response_bytes
}

///|
pub fn ManagementConfig::request_timeout_ms(self : ManagementConfig) -> Int {
  self.request_timeout_ms
}

///|
pub fn ManagementConfig::write_timeout_ms(self : ManagementConfig) -> Int {
  self.write_timeout_ms
}

///|
pub fn ManagementConfig::snapshot_interval_ms(self : ManagementConfig) -> Int {
  self.snapshot_interval_ms
}

///|
pub fn ManagementConfig::snapshot_max_age_ms(self : ManagementConfig) -> Int {
  self.snapshot_max_age_ms
}

///|
pub fn ManagementConfig::ready_require_snapshot_healthy(
  self : ManagementConfig,
) -> Bool {
  self.ready_require_snapshot_healthy
}

///|
pub fn ManagementConfig::request_rate(self : ManagementConfig) -> Int {
  self.request_rate
}

///|
pub fn ManagementConfig::request_burst(self : ManagementConfig) -> Int {
  self.request_burst
}

///|
pub fn ManagementConfig::connection_rate(self : ManagementConfig) -> Int {
  self.connection_rate
}

///|
pub fn ManagementConfig::connection_burst(self : ManagementConfig) -> Int {
  self.connection_burst
}

///|
pub fn ManagementConfig::max_bytes_total(self : ManagementConfig) -> Int64 {
  self.max_bytes_total
}
