///|
pub(all) struct SubscriptionBinding {
  identity : Int64
  filter : @topic.TopicFilter
  qos : @session.DeliveryQoS
  no_local : Bool
  retain_as_published : Bool
  retain_handling : Int
  subscription_identifier : Int?
} derive(Eq, Debug)

///|
pub(all) struct SubscriptionDeliveryMatch {
  client_id : @session.ClientId
  qos : @session.DeliveryQoS
  retain : Bool
  subscription_identifiers : Array[Int]
} derive(Eq, Debug)
