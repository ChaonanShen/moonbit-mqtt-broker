///|
pub(all) struct ConnectV5 {
  client_id : String
  username : String?
  password : Bytes?
  keep_alive : Int
  clean_start : Bool
  properties : Array[Property]
  will : WillV5?
} derive(Eq, Debug)

///|
pub(all) struct WillV5 {
  topic : String
  payload : Bytes
  qos : QoS
  retain : Bool
  properties : Array[Property]
} derive(Eq, Debug)

///|
pub(all) struct ConnackV5 {
  session_present : Bool
  reason : Int
  properties : Array[Property]
} derive(Eq, Debug)

///|
pub(all) struct PublishV5 {
  topic : String
  payload : Bytes
  qos : QoS
  packet_id : PacketId?
  dup : Bool
  retain : Bool
  properties : Array[Property]
} derive(Eq, Debug)

///|
pub(all) struct AckV5 {
  packet_id : PacketId
  reason : Int
  properties : Array[Property]
} derive(Eq, Debug)

///|
pub(all) struct SubscriptionV5 {
  topic_filter : String
  requested_qos : QoS
  no_local : Bool
  retain_as_published : Bool
  retain_handling : Int
} derive(Eq, Debug)

///|
pub(all) struct SubscribeV5 {
  packet_id : PacketId
  properties : Array[Property]
  subscriptions : Array[SubscriptionV5]
} derive(Eq, Debug)

///|
pub(all) struct SubackV5 {
  packet_id : PacketId
  properties : Array[Property]
  reasons : Array[Int]
} derive(Eq, Debug)

///|
pub(all) struct UnsubscribeV5 {
  packet_id : PacketId
  properties : Array[Property]
  topic_filters : Array[String]
} derive(Eq, Debug)

///|
pub(all) struct UnsubackV5 {
  packet_id : PacketId
  properties : Array[Property]
  reasons : Array[Int]
} derive(Eq, Debug)

///|
pub(all) struct DisconnectV5 {
  reason : Int
  properties : Array[Property]
} derive(Eq, Debug)

///|
pub(all) struct AuthV5 {
  reason : Int
  properties : Array[Property]
} derive(Eq, Debug)

///|
pub(all) enum PacketV5 {
  Connect5(ConnectV5)
  Connack5(ConnackV5)
  Publish5(PublishV5)
  Puback5(AckV5)
  Pubrec5(AckV5)
  Pubrel5(AckV5)
  Pubcomp5(AckV5)
  Subscribe5(SubscribeV5)
  Suback5(SubackV5)
  Unsubscribe5(UnsubscribeV5)
  Unsuback5(UnsubackV5)
  Pingreq5
  Pingresp5
  Disconnect5(DisconnectV5)
  Auth5(AuthV5)
} derive(Eq, Debug)

///|
pub(all) enum WirePacket {
  V311(Packet)
  V5(PacketV5)
} derive(Eq, Debug)

///|
pub(all) struct DecodeLimits {
  max_packet_bytes : Int
  max_property_bytes : Int
  max_user_properties : Int
  max_subscription_entries : Int
} derive(Eq, Debug)
