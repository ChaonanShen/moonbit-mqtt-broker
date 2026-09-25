///|
pub(all) enum ConnectionPhase {
  AwaitConnect
  Authenticating(Int64)
  Active(@session.ClientId)
} derive(Eq, Debug)

///|
pub(all) struct StoredWill {
  topic : @topic.TopicName
  payload : Bytes
  qos : @session.DeliveryQoS
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
  AdminKick
  PolicyRevoked
  SlowConsumer
  EncodeFailure
  ResourceExhausted
  RateLimited
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
  principal : @security.Principal?
  policy_epoch : Int64
} derive(Eq, Debug)
