///|
pub(all) enum LimitKind {
  SubscriptionsPerSession
  SubscriptionsTotal
  RetainedMessages
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
  RetainedLimitReached(Int)
  InvariantViolation(String)
} derive(Eq, Debug)
