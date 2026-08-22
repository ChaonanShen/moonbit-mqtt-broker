///|
fn copy_session_bytes(payload : Bytes) -> Bytes {
  Bytes::from_array(payload.to_array())
}

///|
pub(all) struct SessionMessage {
  topic : @topic.TopicName
  payload : Bytes
  retain : Bool
} derive(Eq, Debug)

///|
pub fn SessionMessage::new(
  topic : @topic.TopicName,
  payload : Bytes,
  retain : Bool,
) -> SessionMessage {
  { topic, payload: copy_session_bytes(payload), retain }
}

///|
pub(all) struct OutboundInflight {
  packet_id : SessionPacketId
  message : SessionMessage
} derive(Eq, Debug)

///|
pub(all) struct SessionDelivery {
  packet_id : SessionPacketId
  message : SessionMessage
  dup : Bool
} derive(Eq, Debug)

///|
pub(all) struct SessionLimits {
  max_inflight : Int
  max_pending : Int
} derive(Eq, Debug)

///|
pub fn SessionLimits::new(
  max_inflight : Int,
  max_pending : Int,
) -> Result[SessionLimits, SessionError] {
  if max_inflight < 0 || max_inflight > 65535 {
    Err(InvalidSessionLimit("max_inflight must be in 0..65535"))
  } else if max_pending < 0 {
    Err(InvalidSessionLimit("max_pending must not be negative"))
  } else {
    Ok({ max_inflight, max_pending })
  }
}

///|
pub(all) enum SessionStage {
  SendNow(SessionDelivery)
  Queued
} derive(Eq, Debug)

///|
pub(all) enum SessionAck {
  UnknownPacketId
  Acknowledged(Array[SessionDelivery])
} derive(Eq, Debug)
