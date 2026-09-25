///|
pub(all) struct SnapshotClockV5 {
  sample_wall_ms : Int64
  remaining_ms : Int64
  deadline_wall_ms : Int64
} derive(Eq, Debug)

///|
pub(all) struct SnapshotApplicationPropertiesV5 {
  payload_format : Int?
  content_type : String?
  response_topic : String?
  correlation_data : Bytes?
  user_properties : Array[(String, String)]
} derive(Eq, Debug)

///|
pub(all) struct SnapshotMessageV5 {
  topic : String
  payload : Bytes
  qos : Int
  retain : Bool
  publisher_client_id : String?
  properties : SnapshotApplicationPropertiesV5
  expiry_clock : SnapshotClockV5?
} derive(Eq, Debug)

///|
pub(all) struct SnapshotGroupV5 {
  id : Int64
  incarnation : Int64
  name : String
  inner_filter : String
  state : Int
  revision : Int64
} derive(Eq, Debug)

///|
pub(all) struct SnapshotSharedOriginV5 {
  group_id : Int64
  group_incarnation : Int64
} derive(Eq, Debug)

///|
pub(all) struct SnapshotSubscriptionV5 {
  identity : Int64
  kind : Int
  wire_filter : String
  group_id : Int64?
  group_incarnation : Int64?
  inner_filter : String?
  qos : Int
  no_local : Bool
  retain_as_published : Bool
  retain_handling : Int
  subscription_identifier : UInt?
} derive(Eq, Debug)

///|
pub(all) struct SnapshotPendingV5 {
  delivery_id : Int64
  message : SnapshotMessageV5
  shared_origin : SnapshotSharedOriginV5?
  subscription_identifiers : Array[UInt]
} derive(Eq, Debug)

///|
pub(all) struct SnapshotInflightV5 {
  packet_id : Int
  delivery_id : Int64
  phase : Int
  started : Bool
  message : SnapshotMessageV5?
  shared_origin : SnapshotSharedOriginV5?
  subscription_identifiers : Array[UInt]
} derive(Eq, Debug)

///|
pub(all) struct SnapshotInboundQoS2V5 {
  packet_id : Int
  success_reason : Int
} derive(Eq, Debug)

///|
pub(all) struct SnapshotSessionV5 {
  client_id : String
  owner_principal : String
  incarnation : Int64
  lifecycle_version : Int64
  state_revision : Int64
  last_protocol : Int
  retention : @session.Retention
  attached_at_capture : Bool
  detached_at_wall_ms : Int64?
  session_expiry_clock : SnapshotClockV5?
  next_packet_id : Int
  subscriptions : Array[SnapshotSubscriptionV5]
  inbound_qos2 : Array[SnapshotInboundQoS2V5]
  inflight : Array[SnapshotInflightV5]
  pending : Array[SnapshotPendingV5]
} derive(Eq, Debug)

///|
pub(all) struct SnapshotRetainedV5 {
  revision : Int64
  message : SnapshotMessageV5
} derive(Eq, Debug)

///|
pub(all) struct SnapshotWillV5 {
  id : Int64
  owner_principal : String
  client_id : String
  session_incarnation : Int64
  state : Int
  message_template : SnapshotMessageV5
  delay_seconds : UInt
  will_message_expiry_seconds : UInt?
  trigger_wall_ms : Int64?
  due_clock : SnapshotClockV5?
  policy_sequence : Int64
  revision : Int64
} derive(Eq, Debug)

///|
pub(all) struct BrokerSnapshotV5 {
  clock_floor_wall_ms : Int64
  next_session_incarnation : Int64
  next_subscription_identity : Int64
  next_delivery_id : Int64
  next_group_id : Int64
  next_will_id : Int64
  next_retained_revision : Int64
  groups : Array[SnapshotGroupV5]
  sessions : Array[SnapshotSessionV5]
  retained : Array[SnapshotRetainedV5]
  wills : Array[SnapshotWillV5]
} derive(Eq, Debug)
