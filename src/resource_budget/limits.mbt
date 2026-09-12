///|
pub struct Limits {
  values : Map[String, Int64]
} derive(Eq, Debug)

///|
/// Stable key registry shared by configuration adapters and help output.
pub fn byte_limit_specs() -> Array[(String, String, Int64)] {
  [
    ("resources", "max_managed_bytes_total", 268435456L),
    ("resources", "control_reserve_bytes", 2097152L),
    ("broker", "max_retained_bytes_total", 16777216L),
    ("broker", "max_retained_message_bytes", 1048576L),
    ("broker", "max_inflight_bytes_per_session", 4194304L),
    ("broker", "max_inflight_bytes_total", 33554432L),
    ("broker", "max_pending_bytes_per_session", 8388608L),
    ("broker", "max_pending_bytes_total", 67108864L),
    ("broker", "max_session_state_bytes", 12582912L),
    ("broker", "max_subscription_bytes_per_session", 131072L),
    ("broker", "max_subscription_bytes_total", 8388608L),
    ("broker", "max_session_metadata_bytes_total", 1048576L),
    ("server", "max_will_bytes_per_connection", 1048576L),
    ("server", "max_will_bytes_total", 8388608L),
    ("server", "max_receive_bytes_total", 16777216L),
    ("server", "max_runtime_bytes_per_connection", 2097152L),
    ("server", "max_runtime_bytes_total", 16777216L),
    ("server", "max_outbound_bytes_per_connection", 4194304L),
    ("server", "max_outbound_bytes_total", 33554432L),
    ("server", "max_connection_metadata_bytes_total", 1048576L),
    ("resources", "max_limiter_metadata_bytes_total", 2097152L),
    ("resources", "max_routing_scratch_bytes", 16777216L),
    ("resources", "max_snapshot_work_bytes", 100663296L),
    ("resources", "max_auth_request_bytes_total", 2097152L),
    ("resources", "max_auth_workspace_bytes_total", 134217728L),
    ("resources", "max_auth_result_bytes_total", 1048576L),
  ]
}

///|
pub fn Limits::default() -> Limits {
  let values : Map[String, Int64] = Map([])
  for spec in byte_limit_specs() {
    let (_, key, value) = spec
    values.set(key, value)
  }
  for spec in rate_limit_specs() {
    let (_, key, value) = spec
    values.set(key, value)
  }
  values.set("rate_limits_enabled", 1L)
  values.set("per_ip_limits_enabled", 1L)
  { values, }
}

///|
pub fn Limits::get(self : Limits, key : String) -> Int64 {
  self.values.get(key).unwrap()
}

///|
pub fn Limits::with_value(
  self : Limits,
  key : String,
  value : Int64,
) -> Result[Limits, BudgetError] {
  if value < 0L || !self.values.contains(key) {
    return Err(InvalidConfiguration)
  }
  let values : Map[String, Int64] = Map([])
  for k, v in self.values {
    values.set(k, v)
  }
  values.set(key, value)
  Ok({ values, })
}

///|
pub fn Limits::validate(self : Limits) -> Result[Unit, BudgetError] {
  if self.get("control_reserve_bytes") > self.get("max_managed_bytes_total") {
    return Err(InvalidConfiguration)
  }
  if self.get("rate_limits_enabled") > 1L ||
    self.get("per_ip_limits_enabled") > 1L ||
    self.get("max_ip_buckets") > 1048576L ||
    self.get("max_runtime_events_per_connection") < 1L {
    return Err(InvalidConfiguration)
  }
  Ok(())
}

///|
pub fn rate_limit_specs() -> Array[(String, String, Int64)] {
  [
    ("server", "max_connections_per_ip", 32L),
    ("limits", "connect_rate_per_ip", 10L),
    ("limits", "connect_burst_per_ip", 20L),
    ("limits", "connect_rate_total", 100L),
    ("limits", "connect_burst_total", 200L),
    ("limits", "auth_rate_per_ip", 5L),
    ("limits", "auth_burst_per_ip", 10L),
    ("limits", "auth_rate_total", 20L),
    ("limits", "auth_burst_total", 40L),
    ("limits", "publish_messages_per_session", 100L),
    ("limits", "publish_messages_burst_per_session", 200L),
    ("limits", "publish_bytes_per_session", 1048576L),
    ("limits", "publish_bytes_burst_per_session", 2097152L),
    ("limits", "publish_messages_total", 5000L),
    ("limits", "publish_messages_burst_total", 10000L),
    ("limits", "publish_bytes_total", 16777216L),
    ("limits", "publish_bytes_burst_total", 33554432L),
    ("limits", "ingress_bytes_per_ip", 4194304L),
    ("limits", "ingress_bytes_burst_per_ip", 8388608L),
    ("limits", "ingress_bytes_total", 33554432L),
    ("limits", "ingress_bytes_burst_total", 67108864L),
    ("limits", "control_packets_per_connection", 1000L),
    ("limits", "control_packets_burst_per_connection", 2000L),
    ("limits", "max_ip_buckets", 4096L),
    ("limits", "idle_ttl_ms", 300000L),
    ("server", "max_runtime_events_per_connection", 32L),
  ]
}

///|
pub fn Limits::rates_enabled(self : Limits) -> Bool {
  self.get("rate_limits_enabled") == 1L
}

///|
pub fn Limits::per_ip_enabled(self : Limits) -> Bool {
  self.get("per_ip_limits_enabled") == 1L
}
