///|
pub struct PersistenceConfig {
  data_dir : String
  max_snapshot_bytes : Int64
  debounce_ms : Int64
  max_delay_ms : Int64
  retry_ms : Int64
} derive(Eq, Debug)

///|
pub fn PersistenceConfig::new(
  data_dir : String,
  max_snapshot_bytes? : Int64 = 67108864L,
  debounce_ms? : Int64 = 250L,
  max_delay_ms? : Int64 = 2000L,
  retry_ms? : Int64 = 1000L,
) -> Result[PersistenceConfig, PersistenceError] {
  if data_dir == "" {
    return Err(InvalidConfiguration("data_dir must not be empty"))
  }
  if max_snapshot_bytes < 24L || max_snapshot_bytes > 2147483646L {
    return Err(
      InvalidConfiguration(
        "max_snapshot_bytes must be between 24 and 2147483646",
      ),
    )
  }
  if debounce_ms < 1L {
    return Err(InvalidConfiguration("debounce_ms must be at least 1"))
  }
  if debounce_ms > 2147483647L ||
    max_delay_ms > 2147483647L ||
    retry_ms > 2147483647L {
    return Err(
      InvalidConfiguration("snapshot timing values must fit platform timers"),
    )
  }
  if max_delay_ms < debounce_ms {
    return Err(
      InvalidConfiguration("max_delay_ms must be at least debounce_ms"),
    )
  }
  if retry_ms < 1L {
    return Err(InvalidConfiguration("retry_ms must be at least 1"))
  }
  Ok({ data_dir, max_snapshot_bytes, debounce_ms, max_delay_ms, retry_ms })
}

///|
pub fn PersistenceConfig::data_dir(self : PersistenceConfig) -> String {
  self.data_dir
}

///|
pub fn PersistenceConfig::max_snapshot_bytes(self : PersistenceConfig) -> Int64 {
  self.max_snapshot_bytes
}

///|
pub fn PersistenceConfig::debounce_ms(self : PersistenceConfig) -> Int64 {
  self.debounce_ms
}

///|
pub fn PersistenceConfig::max_delay_ms(self : PersistenceConfig) -> Int64 {
  self.max_delay_ms
}

///|
pub fn PersistenceConfig::retry_ms(self : PersistenceConfig) -> Int64 {
  self.retry_ms
}

///|
pub struct SnapshotDecodeLimits {
  broker_config : @router.BrokerConfig
  max_message_payload_bytes : Int
  max_snapshot_bytes : Int
}

///|
pub fn SnapshotDecodeLimits::new(
  broker_config : @router.BrokerConfig,
  max_message_payload_bytes : Int,
  max_snapshot_bytes? : Int = 67108864,
) -> Result[SnapshotDecodeLimits, PersistenceError] {
  if max_message_payload_bytes < 0 {
    return Err(
      InvalidConfiguration("max_message_payload_bytes must not be negative"),
    )
  }
  if max_snapshot_bytes < 24 {
    return Err(InvalidConfiguration("max_snapshot_bytes must be at least 24"))
  }
  Ok({ broker_config, max_message_payload_bytes, max_snapshot_bytes })
}

///|
pub fn SnapshotDecodeLimits::broker_config(
  self : SnapshotDecodeLimits,
) -> @router.BrokerConfig {
  self.broker_config
}

///|
pub fn SnapshotDecodeLimits::max_message_payload_bytes(
  self : SnapshotDecodeLimits,
) -> Int {
  self.max_message_payload_bytes
}

///|
pub fn SnapshotDecodeLimits::max_snapshot_bytes(
  self : SnapshotDecodeLimits,
) -> Int {
  self.max_snapshot_bytes
}
