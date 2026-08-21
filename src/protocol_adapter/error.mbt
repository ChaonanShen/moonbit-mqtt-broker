///|
/// Stable error categories exposed by the protocol adapter. Diagnostic text is
/// for humans only; callers must match the constructor, never the message.
pub(all) enum CodecError {
  InvalidFixedHeader(String)
  InvalidRemainingLength(String)
  InvalidFlags(String)
  InvalidProtocolName(String)
  InvalidProtocolLevel(String)
  InvalidUtf8(String)
  InvalidPacketId(String)
  InvalidPacketShape(String)
  InvalidDirection(String)
  TrailingBytes(String)
  UnsupportedPacketType(String)
  UnsupportedQoS(String)
  PacketTooLarge(String)
  BackendFailure(String)
} derive(Eq, Debug)

///|
pub(all) enum PacketDirection {
  ClientToServer
  ServerToClient
} derive(Eq, Debug)
