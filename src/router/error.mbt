///|
pub(all) enum LimitKind {
  Bytes
  SubscriptionsPerSession
  SubscriptionsTotal
  RetainedMessages
  Sessions
  InflightPerSession
  InflightTotal
  PendingQoS1PerSession
  PendingQoS1Total
  InboundQoS2PerSession
  InboundQoS2Total
} derive(Eq, Debug)

///|
pub(all) enum RouterError {
  ByteResourceLimit(@budget.BudgetError)
  InvalidConfiguration(String)
  InvalidClientId(@session.SessionError)
  InvalidTopic(@topic.TopicError)
  EmptySubscriptionRequest
  EmptyUnsubscriptionRequest
  SessionAlreadyExists(@session.ClientId)
  SessionNotFound(@session.ClientId)
  SessionLimitReached(Int)
  InvalidSessionState(@session.ClientId)
  QoS1ResourceLimit(@session.ClientId, LimitKind)
  InboundQoS2ResourceLimit(LimitKind)
  SessionFailure(@session.SessionError)
  RetainedLimitReached(Int)
  InvariantViolation(String)
} derive(Eq, Debug)
