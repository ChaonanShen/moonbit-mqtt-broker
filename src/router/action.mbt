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
pub(all) struct DeliveryAcknowledgedAction {
  client_id : @session.ClientId
  packet_id : @session.SessionPacketId
} derive(Eq, Debug)

///|
pub(all) enum BrokerAction {
  SessionCreated(@session.ClientId)
  SessionRemoved(@session.ClientId)
  SessionAttached(@session.ClientId)
  SessionDetached(@session.ClientId)
  SessionExpired(@session.ClientId)
  TimeRegressionDetected(Int64, Int64)
  SubscriptionsApplied(SubscriptionsAppliedAction)
  UnsubscriptionsApplied(UnsubscriptionsAppliedAction)
  DeliveryAcknowledged(DeliveryAcknowledgedAction)
  DeliveryDroppedResourceLimit(@session.ClientId)
  Deliver(RoutedDelivery)
} derive(Eq, Debug)
