///|
pub(all) struct SubscribeEntry {
  filter : @topic.TopicFilter
  qos : @session.DeliveryQoS
} derive(Eq, Debug)

///|
pub(all) struct SubscribeRequest {
  client_id : @session.ClientId
  entries : Array[SubscribeEntry]
} derive(Eq, Debug)

///|
pub(all) struct UnsubscribeRequest {
  client_id : @session.ClientId
  filters : Array[@topic.TopicFilter]
} derive(Eq, Debug)

///|
pub(all) enum BrokerEvent {
  CreateSession(@session.ClientId)
  RemoveSession(@session.ClientId)
  Subscribe(SubscribeRequest)
  Unsubscribe(UnsubscribeRequest)
  Publish(PublishInput)
} derive(Eq, Debug)
