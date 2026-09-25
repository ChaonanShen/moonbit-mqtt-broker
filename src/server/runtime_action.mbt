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
pub(all) struct SendMqtt5Action {
  connection_id : ConnectionId
  packet : @protocol.PacketV5
  close_reason : CloseReason?
} derive(Eq, Debug)

///|
pub(all) struct CloseTransportAction {
  connection_id : ConnectionId
  reason : CloseReason
} derive(Eq, Debug)

///|
pub(all) struct StartAuthenticationAction {
  request_id : Int64
} derive(Eq, Debug)

///|
pub(all) struct CancelAuthenticationAction {
  request_id : Int64
} derive(Eq, Debug)

///|
pub(all) enum RuntimeAction {
  SendPacket(SendPacketAction)
  SendPacketThenClose(SendPacketThenCloseAction)
  SendMqtt5(SendMqtt5Action)
  CloseTransport(CloseTransportAction)
  StartAuthentication(StartAuthenticationAction)
  CancelAuthentication(CancelAuthenticationAction)
  StartDurableWill(ConnectionId)
} derive(Eq, Debug)
