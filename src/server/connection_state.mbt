///|
pub(all) enum ConnectionPhase {
  AwaitConnect
  Active(@session.ClientId)
} derive(Eq, Debug)

///|
pub(all) struct StoredWill {
  topic : @topic.TopicName
  payload : Bytes
  retain : Bool
} derive(Eq, Debug)

///|
pub(all) enum CloseReason {
  NormalDisconnect
  ConnectRejected
  PeerEof
  ReadFailure
  WriteFailure
  ProtocolError
  KeepAliveTimeout
  ConnectTimeout
  ClientTakeover
  SlowConsumer
  EncodeFailure
  ServerShutdown
} derive(Eq, Debug)

///|
pub(all) struct ConnectionMeta {
  id : ConnectionId
  phase : ConnectionPhase
  accepted_at_ms : Int64
  last_control_at_ms : Int64
  keep_alive_seconds : Int
  will : StoredWill?
} derive(Eq, Debug)
