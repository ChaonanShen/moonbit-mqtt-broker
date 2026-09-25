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
  SubscribeV5(SubscribeV5Request)
  Unsubscribe(UnsubscribeRequest)
  Publish(PublishInput)
  PublishV5(PublishInputV5)
  Puback(PubackRequest)
  Pubrec(PubackRequest)
  Pubrel(PubackRequest)
  Pubcomp(PubackRequest)
  ReceiveQoS2(InboundQoS2Request)
  ReceiveQoS2V5(InboundQoS2RequestV5)
} derive(Eq, Debug)

///|
/// None is an ACL-dropped exchange that must still finish the handshake.
pub(all) struct InboundQoS2Request {
  client_id : @session.ClientId
  packet_id : @session.SessionPacketId
  publish : PublishInput?
} derive(Eq, Debug)

///|
pub(all) struct InboundQoS2RequestV5 {
  client_id : @session.ClientId
  packet_id : @session.SessionPacketId
  publish : PublishInputV5?
} derive(Eq, Debug)

///|
pub(all) struct SubscribeEntryV5 {
  filter : @topic.TopicFilter
  qos : @session.DeliveryQoS
  no_local : Bool
  retain_as_published : Bool
  retain_handling : Int
  subscription_identifier : Int?
} derive(Eq, Debug)

///|
pub(all) struct SubscribeV5Request {
  client_id : @session.ClientId
  entries : Array[SubscribeEntryV5]
} derive(Eq, Debug)
