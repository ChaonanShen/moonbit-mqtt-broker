///|
pub(all) struct ProtocolConfig {
  mqtt5_enabled : Bool
  server_receive_maximum : Int
  server_keep_alive : Int
  topic_alias_maximum : Int
  max_property_bytes : Int
  max_user_properties : Int
  max_subscription_entries : Int
  max_alias_bytes_per_connection : Int
  max_delayed_wills : Int
  max_expiry_work_per_turn : Int
  write_timeout_ms : Int
} derive(Eq, Debug)

///|
pub(all) enum ProtocolConfigError {
  InvalidProtocolConfig(String)
} derive(Eq, Debug)

///|
pub fn ProtocolConfig::new(
  mqtt5_enabled? : Bool = false,
  server_receive_maximum? : Int = 16,
  server_keep_alive? : Int = -1,
  topic_alias_maximum? : Int = 32,
  max_property_bytes? : Int = 16384,
  max_user_properties? : Int = 64,
  max_subscription_entries? : Int = 256,
  max_alias_bytes_per_connection? : Int = 65536,
  max_delayed_wills? : Int = 1024,
  max_expiry_work_per_turn? : Int = 128,
  write_timeout_ms? : Int = 10000,
) -> Result[ProtocolConfig, ProtocolConfigError] {
  if server_receive_maximum < 1 || server_receive_maximum > 65535 {
    return Err(
      InvalidProtocolConfig("server_receive_maximum must be in 1..65535"),
    )
  }
  if server_keep_alive < -1 || server_keep_alive > 65535 {
    return Err(InvalidProtocolConfig("server_keep_alive must be in -1..65535"))
  }
  if topic_alias_maximum < 0 || topic_alias_maximum > 65535 {
    return Err(InvalidProtocolConfig("topic_alias_maximum must be in 0..65535"))
  }
  if max_property_bytes < 1 {
    return Err(InvalidProtocolConfig("max_property_bytes must be positive"))
  }
  if max_user_properties < 0 || max_user_properties > 1024 {
    return Err(InvalidProtocolConfig("max_user_properties must be in 0..1024"))
  }
  if max_subscription_entries < 1 || max_subscription_entries > 65535 {
    return Err(
      InvalidProtocolConfig("max_subscription_entries must be in 1..65535"),
    )
  }
  if max_alias_bytes_per_connection < 0 {
    return Err(
      InvalidProtocolConfig(
        "max_alias_bytes_per_connection must not be negative",
      ),
    )
  }
  if max_delayed_wills < 0 {
    return Err(InvalidProtocolConfig("max_delayed_wills must not be negative"))
  }
  if max_expiry_work_per_turn < 1 || max_expiry_work_per_turn > 1024 {
    return Err(
      InvalidProtocolConfig("max_expiry_work_per_turn must be in 1..1024"),
    )
  }
  if write_timeout_ms < 1 || write_timeout_ms > 600000 {
    return Err(InvalidProtocolConfig("write_timeout_ms must be in 1..600000"))
  }
  Ok({
    mqtt5_enabled,
    server_receive_maximum,
    server_keep_alive,
    topic_alias_maximum,
    max_property_bytes,
    max_user_properties,
    max_subscription_entries,
    max_alias_bytes_per_connection,
    max_delayed_wills,
    max_expiry_work_per_turn,
    write_timeout_ms,
  })
}
