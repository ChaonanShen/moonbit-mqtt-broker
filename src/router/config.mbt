///|
pub struct BrokerConfig {
  max_subscriptions_per_session : Int
  max_subscriptions_total : Int
  max_retained_messages : Int
  max_sessions : Int
  max_inflight_per_session : Int
  max_inflight_total : Int
  max_pending_qos1_per_session : Int
  max_pending_qos1_total : Int
  persistent_session_expiry_ms : Int64
  max_session_expirations_per_tick : Int
} derive(Eq, Debug)

///|
pub fn BrokerConfig::new(
  per_session : Int,
  total : Int,
  retained : Int,
  max_sessions? : Int = 1024,
  max_inflight_per_session? : Int = 16,
  max_inflight_total? : Int = 512,
  max_pending_qos1_per_session? : Int = 64,
  max_pending_qos1_total? : Int = 1024,
  persistent_session_expiry_ms? : Int64 = -1L,
  max_session_expirations_per_tick? : Int = 128,
) -> Result[BrokerConfig, RouterError] {
  if per_session < 0 ||
    total < 0 ||
    retained < 0 ||
    max_sessions < 0 ||
    max_inflight_per_session < 0 ||
    max_inflight_total < 0 ||
    max_pending_qos1_per_session < 0 ||
    max_pending_qos1_total < 0 ||
    persistent_session_expiry_ms < -1L ||
    max_session_expirations_per_tick < 1 {
    Err(InvalidConfiguration("resource limits must not be negative"))
  } else if max_inflight_per_session > 65535 {
    Err(InvalidConfiguration("max_inflight_per_session must not exceed 65535"))
  } else {
    Ok({
      max_subscriptions_per_session: per_session,
      max_subscriptions_total: total,
      max_retained_messages: retained,
      max_sessions,
      max_inflight_per_session,
      max_inflight_total,
      max_pending_qos1_per_session,
      max_pending_qos1_total,
      persistent_session_expiry_ms,
      max_session_expirations_per_tick,
    })
  }
}

///|
pub fn BrokerConfig::max_subscriptions_per_session(self : BrokerConfig) -> Int {
  self.max_subscriptions_per_session
}

///|
pub fn BrokerConfig::max_subscriptions_total(self : BrokerConfig) -> Int {
  self.max_subscriptions_total
}

///|
pub fn BrokerConfig::max_retained_messages(self : BrokerConfig) -> Int {
  self.max_retained_messages
}

///|
pub fn BrokerConfig::max_sessions(self : BrokerConfig) -> Int {
  self.max_sessions
}

///|
pub fn BrokerConfig::max_inflight_per_session(self : BrokerConfig) -> Int {
  self.max_inflight_per_session
}

///|
pub fn BrokerConfig::max_inflight_total(self : BrokerConfig) -> Int {
  self.max_inflight_total
}

///|
pub fn BrokerConfig::max_pending_qos1_per_session(self : BrokerConfig) -> Int {
  self.max_pending_qos1_per_session
}

///|
pub fn BrokerConfig::max_pending_qos1_total(self : BrokerConfig) -> Int {
  self.max_pending_qos1_total
}

///|
pub fn BrokerConfig::persistent_session_expiry_ms(
  self : BrokerConfig,
) -> Int64? {
  if self.persistent_session_expiry_ms < 0L {
    None
  } else {
    Some(self.persistent_session_expiry_ms)
  }
}

///|
pub fn BrokerConfig::max_session_expirations_per_tick(
  self : BrokerConfig,
) -> Int {
  self.max_session_expirations_per_tick
}
