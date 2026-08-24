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
pub(all) struct CreateSessionRequest {
  client_id : @session.ClientId
  mode : @session.SessionMode
  attached : Bool
} derive(Eq, Debug)

///|
pub(all) struct CreateOwnedSessionRequest {
  client_id : @session.ClientId
  mode : @session.SessionMode
  attached : Bool
  owner : @security.Principal
} derive(Eq, Debug)

///|
pub(all) struct DetachSessionRequest {
  client_id : @session.ClientId
  detached_at_ms : Int64
} derive(Eq, Debug)

///|
pub(all) struct PubackRequest {
  client_id : @session.ClientId
  packet_id : @session.SessionPacketId
} derive(Eq, Debug)

///|
pub(all) enum BrokerEvent {
  CreateSession(@session.ClientId)
  CreateSessionWith(CreateSessionRequest)
  CreateOwnedSessionWith(CreateOwnedSessionRequest)
  RemoveSession(@session.ClientId)
  AttachSession(@session.ClientId)
  DetachSession(@session.ClientId)
  DetachSessionAt(DetachSessionRequest)
  ExpireSessions(Int64)
  Subscribe(SubscribeRequest)
  Unsubscribe(UnsubscribeRequest)
  Publish(PublishInput)
  Puback(PubackRequest)
} derive(Eq, Debug)
