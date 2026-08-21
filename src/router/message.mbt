///|
pub(all) enum PublishOrigin {
  Client(@session.ClientId)
  Will(@session.ClientId)
  Internal
} derive(Eq, Debug)

///|
pub(all) struct PublishInput {
  origin : PublishOrigin
  topic : @topic.TopicName
  payload : Bytes
  qos : @session.DeliveryQoS
  retain : Bool
} derive(Eq, Debug)

///|
pub(all) struct RetainedMessage {
  topic : @topic.TopicName
  payload : Bytes
  qos : @session.DeliveryQoS
} derive(Eq, Debug)

///|
pub(all) struct RoutedDelivery {
  recipient : @session.ClientId
  topic : @topic.TopicName
  payload : Bytes
  qos : @session.DeliveryQoS
  retain : Bool
} derive(Eq, Debug)
