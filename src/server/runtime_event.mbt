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
pub(all) enum RuntimeEvent {
  TransportOpened(TransportOpenedEvent)
  PacketReceived(PacketReceivedEvent)
  TransportClosed(TransportClosedEvent)
  CheckDeadlines(Int64)
  EmitSystemMetrics(EmitSystemMetricsEvent)
} derive(Eq, Debug)
