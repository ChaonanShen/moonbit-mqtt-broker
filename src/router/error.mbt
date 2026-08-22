///|
pub(all) enum LimitKind {
  SubscriptionsPerSession
  SubscriptionsTotal
  RetainedMessages
  Sessions
  InflightPerSession
  InflightTotal
  PendingQoS1PerSession
  PendingQoS1Total
} derive(Eq, Debug)

///|
pub(all) enum RouterError {
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
  SessionFailure(@session.SessionError)
  RetainedLimitReached(Int)
  InvariantViolation(String)
} derive(Eq, Debug)
