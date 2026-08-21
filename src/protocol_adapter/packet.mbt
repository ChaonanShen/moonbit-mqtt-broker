///|
pub(all) enum QoS {
  QoS0
  QoS1
  QoS2
} derive(Eq, Debug)

///|
/// MQTT packet identifiers are always in the inclusive range 1..65535.
pub struct PacketId {
  value : Int
} derive(Eq, Debug)

///|
pub fn PacketId::new(value : Int) -> Result[PacketId, CodecError] {
  if value < 1 || value > 65535 {
    Err(InvalidPacketId("packet identifier must be in 1..65535"))
  } else {
    Ok({ value, })
  }
}

///|
pub fn PacketId::value(self : PacketId) -> Int {
  self.value
}

///|
pub(all) struct WillMessage {
  topic : String
  payload : Bytes
  qos : QoS
  retain : Bool
} derive(Eq, Debug)

///|
pub(all) struct ConnectPacket {
  client_id : String
  username : String?
  password : Bytes?
  keep_alive : Int
  clean_session : Bool
  will : WillMessage?
} derive(Eq, Debug)

///|
pub(all) enum ConnectReturnCode {
  Accepted
  UnacceptableProtocolVersion
  IdentifierRejected
  ServerUnavailable
  BadUsernameOrPassword
  NotAuthorized
} derive(Eq, Debug)

///|
pub(all) struct ConnackPacket {
  session_present : Bool
  return_code : ConnectReturnCode
} derive(Eq, Debug)

///|
pub(all) struct PublishPacket {
  topic : String
  payload : Bytes
  qos : QoS
  packet_id : PacketId?
  dup : Bool
  retain : Bool
} derive(Eq, Debug)

///|
pub(all) struct Subscription {
  topic_filter : String
  requested_qos : QoS
} derive(Eq, Debug)

///|
pub(all) struct SubscribePacket {
  packet_id : PacketId
  subscriptions : Array[Subscription]
} derive(Eq, Debug)

///|
pub(all) enum SubackReturnCode {
  GrantedQoS0
  GrantedQoS1
  GrantedQoS2
  Failure
} derive(Eq, Debug)

///|
pub(all) struct SubackPacket {
  packet_id : PacketId
  return_codes : Array[SubackReturnCode]
} derive(Eq, Debug)

///|
pub(all) struct UnsubscribePacket {
  packet_id : PacketId
  topic_filters : Array[String]
} derive(Eq, Debug)

///|
pub(all) enum Packet {
  Connect(ConnectPacket)
  Connack(ConnackPacket)
  Publish(PublishPacket)
  Puback(PacketId)
  Subscribe(SubscribePacket)
  Suback(SubackPacket)
  Unsubscribe(UnsubscribePacket)
  Unsuback(PacketId)
  Pingreq
  Pingresp
  Disconnect
} derive(Eq, Debug)
