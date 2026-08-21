///|
pub(all) enum SubscribeResult {
  Granted(@session.DeliveryQoS)
  RejectedLimit(LimitKind)
} derive(Eq, Debug)

///|
pub(all) struct SubscriptionsAppliedAction {
  client_id : @session.ClientId
  results : Array[SubscribeResult]
} derive(Eq, Debug)

///|
pub(all) struct UnsubscriptionsAppliedAction {
  client_id : @session.ClientId
  removed : Array[Bool]
} derive(Eq, Debug)

///|
pub(all) enum BrokerAction {
  SessionCreated(@session.ClientId)
  SessionRemoved(@session.ClientId)
  SubscriptionsApplied(SubscriptionsAppliedAction)
  UnsubscriptionsApplied(UnsubscriptionsAppliedAction)
  Deliver(RoutedDelivery)
} derive(Eq, Debug)
