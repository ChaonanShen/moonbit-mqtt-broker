///|
fn copy_session_bytes(payload : Bytes) -> Bytes {
  Bytes::from_array(payload.to_array())
}

///|
pub(all) struct SessionMessage {
  topic : @topic.TopicName
  payload : Bytes
  retain : Bool
  qos : DeliveryQoS
} derive(Eq, Debug)

///|
pub fn SessionMessage::new(
  topic : @topic.TopicName,
  payload : Bytes,
  retain : Bool,
  qos? : DeliveryQoS = QoS1,
) -> SessionMessage {
  { topic, payload: copy_session_bytes(payload), retain, qos }
}

///|
pub(all) enum OutboundPhase {
  AwaitPuback
  AwaitPubrec
  AwaitPubcomp
} derive(Eq, Debug)

///|
pub(all) struct OutboundInflight {
  packet_id : SessionPacketId
  message : SessionMessage?
  phase : OutboundPhase
} derive(Eq, Debug)

///|
pub(all) struct SessionDelivery {
  packet_id : SessionPacketId
  message : SessionMessage?
  dup : Bool
} derive(Eq, Debug)

///|
pub(all) struct SessionLimits {
  max_inflight : Int
  max_pending : Int
  max_inbound_qos2 : Int
} derive(Eq, Debug)

///|
pub fn SessionLimits::new(
  max_inflight : Int,
  max_pending : Int,
  max_inbound_qos2? : Int = 64,
) -> Result[SessionLimits, SessionError] {
  if max_inflight < 0 || max_inflight > 65535 {
    Err(InvalidSessionLimit("max_inflight must be in 0..65535"))
  } else if max_pending < 0 {
    Err(InvalidSessionLimit("max_pending must not be negative"))
  } else if max_inbound_qos2 < 0 || max_inbound_qos2 > 65535 {
    Err(InvalidSessionLimit("max_inbound_qos2 must be in 0..65535"))
  } else {
    Ok({ max_inflight, max_pending, max_inbound_qos2 })
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

///|
pub fn SessionMessage::copy(self : SessionMessage) -> SessionMessage {
  SessionMessage::new(self.topic, self.payload, self.retain, qos=self.qos)
}

///|
pub fn OutboundInflight::copy(self : OutboundInflight) -> OutboundInflight {
  { ..self, message: self.message.map(message => message.copy()) }
}
