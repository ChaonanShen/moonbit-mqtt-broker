///|
pub(all) struct SendPacketAction {
  connection_id : ConnectionId
  packet : @protocol.Packet
} derive(Eq, Debug)

///|
pub(all) struct SendPacketThenCloseAction {
  connection_id : ConnectionId
  packet : @protocol.Packet
  reason : CloseReason
} derive(Eq, Debug)

///|
pub(all) struct CloseTransportAction {
  connection_id : ConnectionId
  reason : CloseReason
} derive(Eq, Debug)

///|
pub(all) enum RuntimeAction {
  SendPacket(SendPacketAction)
  SendPacketThenClose(SendPacketThenCloseAction)
  CloseTransport(CloseTransportAction)
} derive(Eq, Debug)
