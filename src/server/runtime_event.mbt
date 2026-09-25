///|
pub(all) struct TransportOpenedEvent {
  connection_id : ConnectionId
  accepted_at_ms : Int64
} derive(Eq, Debug)

///|
pub(all) struct PacketReceivedEvent {
  connection_id : ConnectionId
  packet : @protocol.Packet
  received_at_ms : Int64
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5PacketReceivedEvent {
  connection_id : ConnectionId
  packet : @protocol.PacketV5
  received_at_ms : Int64
  rx_permit : RxPermit?
  rx_error : Int?
} derive(Eq, Debug)

///|
pub(all) struct WriteNotStartedEvent {
  connection_id : ConnectionId
  client_id : @session.ClientId
  session_incarnation : Int64?
  packet_id : @protocol.PacketId
  qos : @protocol.QoS
} derive(Eq, Debug)

///|
pub(all) struct TransportClosedEvent {
  connection_id : ConnectionId
  reason : CloseReason
  observed_at_ms : Int64
} derive(Eq, Debug)

///|
pub(all) struct EmitSystemMetricsEvent {
  now_ms : Int64
  persistence_state : String
} derive(Eq, Debug)

///|
pub(all) struct AuthenticationCompletedEvent {
  request_id : Int64
  outcome : @security.AuthCompletionOutcome
  completed_at_ms : Int64
} derive(Eq, Debug)

///|
pub(all) enum RuntimeEvent {
  TransportOpened(TransportOpenedEvent)
  PacketReceived(PacketReceivedEvent)
  Mqtt5PacketReceived(Mqtt5PacketReceivedEvent)
  WriteNotStarted(WriteNotStartedEvent)
  TransportClosed(TransportClosedEvent)
  CheckDeadlines(Int64)
  AuthenticationPollDue(Int64)
  EmitSystemMetrics(EmitSystemMetricsEvent)
  AuthenticationCompleted(AuthenticationCompletedEvent)
  AuthenticationSubmitFailed(Int64)
} derive(Eq, Debug)
