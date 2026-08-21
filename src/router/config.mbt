///|
pub struct BrokerConfig {
  max_subscriptions_per_session : Int
  max_subscriptions_total : Int
  max_retained_messages : Int
} derive(Eq, Debug)

///|
pub fn BrokerConfig::new(
  per_session : Int,
  total : Int,
  retained : Int,
) -> Result[BrokerConfig, RouterError] {
  if per_session < 0 || total < 0 || retained < 0 {
    Err(InvalidConfiguration("resource limits must not be negative"))
  } else {
    Ok({
      max_subscriptions_per_session: per_session,
      max_subscriptions_total: total,
      max_retained_messages: retained,
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
