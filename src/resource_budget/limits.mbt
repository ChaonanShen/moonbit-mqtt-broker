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
  Ok(())
}
