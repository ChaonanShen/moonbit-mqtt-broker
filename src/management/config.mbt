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
  details_enabled : Bool
  operations_enabled : Bool
  query_queue_limit : Int
  operation_queue_limit : Int
  max_operation_records : Int
  max_running_operations : Int
  operation_timeout_ms : Int
  operation_retention_ms : Int
  max_cursor_records : Int
  cursor_ttl_ms : Int
  default_page_size : Int
  max_page_size : Int
  query_scan_limit : Int
  query_timeout_ms : Int
  max_audit_records : Int
  command_rate : Int
  command_burst : Int
  max_index_bytes : Int64
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
  details_enabled? : Bool = false,
  operations_enabled? : Bool = false,
  query_queue_limit? : Int = 16,
  operation_queue_limit? : Int = 16,
  max_operation_records? : Int = 256,
  max_running_operations? : Int = 8,
  operation_timeout_ms? : Int = 30000,
  operation_retention_ms? : Int = 900000,
  max_cursor_records? : Int = 256,
  cursor_ttl_ms? : Int = 60000,
  default_page_size? : Int = 50,
  max_page_size? : Int = 100,
  query_scan_limit? : Int = 256,
  query_timeout_ms? : Int = 2000,
  max_audit_records? : Int = 1024,
  command_rate? : Int = 5,
  command_burst? : Int = 10,
  max_index_bytes? : Int64 = 8388608L,
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
  if details_enabled && !enabled {
    return Err(Invalid("details_enabled"))
  }
  if operations_enabled && !details_enabled {
    return Err(Invalid("operations_enabled"))
  }
  if query_queue_limit < 1 || query_queue_limit > 64 {
    return Err(Invalid("query_queue_limit"))
  }
  if operation_queue_limit < 1 || operation_queue_limit > 64 {
    return Err(Invalid("operation_queue_limit"))
  }
  if max_operation_records < 16 || max_operation_records > 4096 {
    return Err(Invalid("max_operation_records"))
  }
  if max_running_operations < 1 ||
    max_running_operations > 32 ||
    max_running_operations > max_operation_records {
    return Err(Invalid("max_running_operations"))
  }
  if operation_timeout_ms < 1000 || operation_timeout_ms > 120000 {
    return Err(Invalid("operation_timeout_ms"))
  }
  if operation_retention_ms < 1000 || operation_retention_ms > 3600000 {
    return Err(Invalid("operation_retention_ms"))
  }
  if max_cursor_records < 16 || max_cursor_records > 4096 {
    return Err(Invalid("max_cursor_records"))
  }
  if cursor_ttl_ms < 1000 || cursor_ttl_ms > 300000 {
    return Err(Invalid("cursor_ttl_ms"))
  }
  if max_page_size < 1 || max_page_size > 500 {
    return Err(Invalid("max_page_size"))
  }
  if default_page_size < 1 || default_page_size > max_page_size {
    return Err(Invalid("default_page_size"))
  }
  if query_scan_limit < max_page_size || query_scan_limit > 2048 {
    return Err(Invalid("query_scan_limit"))
  }
  if query_timeout_ms < 100 ||
    (details_enabled && query_timeout_ms > request_timeout_ms) {
    return Err(Invalid("query_timeout_ms"))
  }
  if max_audit_records < 64 || max_audit_records > 16384 {
    return Err(Invalid("max_audit_records"))
  }
  if command_rate < 1 || command_rate > 1000 {
    return Err(Invalid("command_rate"))
  }
  if command_burst < 1 || command_burst > 2000 {
    return Err(Invalid("command_burst"))
  }
  if max_index_bytes < 1L ||
    (details_enabled && max_index_bytes > max_bytes_total) {
    return Err(Invalid("max_index_bytes"))
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
    details_enabled,
    operations_enabled,
    query_queue_limit,
    operation_queue_limit,
    max_operation_records,
    max_running_operations,
    operation_timeout_ms,
    operation_retention_ms,
    max_cursor_records,
    cursor_ttl_ms,
    default_page_size,
    max_page_size,
    query_scan_limit,
    query_timeout_ms,
    max_audit_records,
    command_rate,
    command_burst,
    max_index_bytes,
  }
  if enabled && config.required_bytes() > max_bytes_total {
    return Err(Invalid("max_bytes_total"))
  }
  if enabled && max_response_bytes < worst_case_response_bytes() {
    return Err(Invalid("max_response_bytes"))
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
  let base = infrastructure + sockets * request_slot + cache
  if !self.details_enabled {
    return base
  }
  let query = self.query_queue_limit.to_int64() * (1024L + 4L * response)
  let cursor = self.max_cursor_records.to_int64() * 512L
  let operations = if self.operations_enabled {
    self.max_operation_records.to_int64() * 2048L +
    self.operation_queue_limit.to_int64() * 512L +
    self.max_audit_records.to_int64() * 512L
  } else {
    0L
  }
  base + self.max_index_bytes + query + cursor + operations
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

///|
/// Conservative capacity fee, including fixed slots, free lists and reverse
/// mappings. Actual startup capacities must fit max_index_bytes.
pub fn ManagementConfig::index_required_bytes(
  self : ManagementConfig,
  max_sessions : Int,
  max_connections : Int,
  max_subscriptions_total : Int,
  max_retained_messages : Int,
) -> Int64 {
  if !self.details_enabled {
    return 0L
  }
  max_sessions.to_int64() * 256L +
  max_connections.to_int64() * 192L +
  max_subscriptions_total.to_int64() * 192L +
  max_retained_messages.to_int64() * 128L
}

///|
pub fn ManagementConfig::details_enabled(self : ManagementConfig) -> Bool {
  self.details_enabled
}

///|
pub fn ManagementConfig::operations_enabled(self : ManagementConfig) -> Bool {
  self.operations_enabled
}

///|
pub fn ManagementConfig::query_queue_limit(self : ManagementConfig) -> Int {
  self.query_queue_limit
}

///|
pub fn ManagementConfig::operation_queue_limit(self : ManagementConfig) -> Int {
  self.operation_queue_limit
}

///|
pub fn ManagementConfig::max_operation_records(self : ManagementConfig) -> Int {
  self.max_operation_records
}

///|
pub fn ManagementConfig::max_running_operations(self : ManagementConfig) -> Int {
  self.max_running_operations
}

///|
pub fn ManagementConfig::operation_timeout_ms(self : ManagementConfig) -> Int {
  self.operation_timeout_ms
}

///|
pub fn ManagementConfig::operation_retention_ms(self : ManagementConfig) -> Int {
  self.operation_retention_ms
}

///|
pub fn ManagementConfig::max_cursor_records(self : ManagementConfig) -> Int {
  self.max_cursor_records
}

///|
pub fn ManagementConfig::cursor_ttl_ms(self : ManagementConfig) -> Int {
  self.cursor_ttl_ms
}

///|
pub fn ManagementConfig::default_page_size(self : ManagementConfig) -> Int {
  self.default_page_size
}

///|
pub fn ManagementConfig::max_page_size(self : ManagementConfig) -> Int {
  self.max_page_size
}

///|
pub fn ManagementConfig::query_scan_limit(self : ManagementConfig) -> Int {
  self.query_scan_limit
}

///|
pub fn ManagementConfig::query_timeout_ms(self : ManagementConfig) -> Int {
  self.query_timeout_ms
}

///|
pub fn ManagementConfig::max_audit_records(self : ManagementConfig) -> Int {
  self.max_audit_records
}

///|
pub fn ManagementConfig::command_rate(self : ManagementConfig) -> Int {
  self.command_rate
}

///|
pub fn ManagementConfig::command_burst(self : ManagementConfig) -> Int {
  self.command_burst
}

///|
pub fn ManagementConfig::max_index_bytes(self : ManagementConfig) -> Int64 {
  self.max_index_bytes
}
