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
  metadata : MessageMetadata
} derive(Eq, Debug)

///|
pub fn SessionMessage::new(
  topic : @topic.TopicName,
  payload : Bytes,
  retain : Bool,
  qos? : DeliveryQoS = QoS1,
  metadata? : MessageMetadata = MessageMetadata::empty(),
) -> SessionMessage {
  {
    topic,
    payload: copy_session_bytes(payload),
    retain,
    qos,
    metadata: metadata.copy(),
  }
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
  max_inflight_bytes : Int64
  max_pending_bytes : Int64
  max_state_bytes : Int64
  max_inflight : Int
  max_pending : Int
  max_inbound_qos2 : Int
} derive(Eq, Debug)

///|
pub fn SessionLimits::new(
  max_inflight : Int,
  max_pending : Int,
  max_inbound_qos2? : Int = 64,
  max_inflight_bytes? : Int64 = 4194304L,
  max_pending_bytes? : Int64 = 8388608L,
  max_state_bytes? : Int64 = 12582912L,
) -> Result[SessionLimits, SessionError] {
  if max_inflight_bytes < 0L || max_pending_bytes < 0L || max_state_bytes < 0L {
    return Err(InvalidSessionLimit("byte limits must not be negative"))
  }
  if max_inflight < 0 || max_inflight > 65535 {
    Err(InvalidSessionLimit("max_inflight must be in 0..65535"))
  } else if max_pending < 0 {
    Err(InvalidSessionLimit("max_pending must not be negative"))
  } else if max_inbound_qos2 < 0 || max_inbound_qos2 > 65535 {
    Err(InvalidSessionLimit("max_inbound_qos2 must be in 0..65535"))
  } else {
    Ok({
      max_inflight,
      max_pending,
      max_inbound_qos2,
      max_inflight_bytes,
      max_pending_bytes,
      max_state_bytes,
    })
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
  SessionMessage::new(
    self.topic,
    self.payload,
    self.retain,
    qos=self.qos,
    metadata=self.metadata,
  )
}

///|
pub fn OutboundInflight::copy(self : OutboundInflight) -> OutboundInflight {
  { ..self, message: self.message.map(message => message.copy()) }
}

///|
pub fn SessionMessage::cost(self : SessionMessage) -> Int64 {
  @budget.checked_add(
    @budget.message_cost(self.topic.value(), self.payload.length().to_int64()).unwrap(),
    self.metadata.cost(),
  ).unwrap()
}

///|
pub fn OutboundInflight::cost(self : OutboundInflight) -> Int64 {
  match self.message {
    Some(message) => message.cost()
    None => @budget.qos2_metadata_cost()
  }
}
