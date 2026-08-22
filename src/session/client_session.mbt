///|
pub struct ClientSession {
  client_id : ClientId
  mode : SessionMode
  mut attached : Bool
  allocator : PacketIdAllocator
  mut inflight : Array[OutboundInflight]
  mut pending : Array[SessionMessage]
} derive(Eq, Debug)

///|
pub fn ClientSession::new(
  client_id : ClientId,
  mode? : SessionMode = Clean,
  attached? : Bool = true,
) -> ClientSession {
  {
    client_id,
    mode,
    attached,
    allocator: PacketIdAllocator::new().unwrap(),
    inflight: [],
    pending: [],
  }
}

///|
pub fn ClientSession::restore(
  client_id : ClientId,
  next_packet_id : Int,
  inflight : Array[OutboundInflight],
  pending : Array[SessionMessage],
) -> Result[ClientSession, SessionError] {
  let allocator = match PacketIdAllocator::new(next=next_packet_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stored_inflight : Array[OutboundInflight] = []
  for item in inflight {
    if stored_inflight.any(existing => existing.packet_id == item.packet_id) {
      return Err(
        SessionInvariantViolation("duplicate restored inflight packet id"),
      )
    }
    stored_inflight.push({
      packet_id: item.packet_id,
      message: SessionMessage::new(
        item.message.topic,
        item.message.payload,
        item.message.retain,
      ),
    })
  }
  let stored_pending = pending.map(message => {
    SessionMessage::new(message.topic, message.payload, message.retain)
  })
  Ok({
    client_id,
    mode: Persistent,
    attached: false,
    allocator,
    inflight: stored_inflight,
    pending: stored_pending,
  })
}

///|
pub fn ClientSession::client_id(self : ClientSession) -> ClientId {
  self.client_id
}

///|
pub fn ClientSession::mode(self : ClientSession) -> SessionMode {
  self.mode
}

///|
pub fn ClientSession::is_attached(self : ClientSession) -> Bool {
  self.attached
}

///|
pub fn ClientSession::inflight_count(self : ClientSession) -> Int {
  self.inflight.length()
}

///|
pub fn ClientSession::pending_count(self : ClientSession) -> Int {
  self.pending.length()
}

///|
pub fn ClientSession::next_packet_id(self : ClientSession) -> Int {
  self.allocator.next()
}

///|
pub fn ClientSession::inflight(self : ClientSession) -> Array[OutboundInflight] {
  self.inflight.map(item => {
    packet_id: item.packet_id,
    message: SessionMessage::new(
      item.message.topic,
      item.message.payload,
      item.message.retain,
    ),
  })
}

///|
pub fn ClientSession::pending(self : ClientSession) -> Array[SessionMessage] {
  self.pending.map(message => {
    SessionMessage::new(message.topic, message.payload, message.retain)
  })
}

///|
fn ClientSession::packet_id_in_use(
  self : ClientSession,
  packet_id : SessionPacketId,
) -> Bool {
  self.inflight.any(item => item.packet_id == packet_id)
}

///|
fn ClientSession::stage_inflight(
  self : ClientSession,
  message : SessionMessage,
) -> Result[SessionDelivery, SessionError] {
  let packet_id = match
    self.allocator.allocate(id => self.packet_id_in_use(id)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stored = SessionMessage::new(
    message.topic,
    message.payload,
    message.retain,
  )
  self.inflight.push({ packet_id, message: stored })
  Ok({
    packet_id,
    message: SessionMessage::new(message.topic, message.payload, message.retain),
    dup: false,
  })
}

///|
pub fn ClientSession::stage(
  self : ClientSession,
  message : SessionMessage,
  limits : SessionLimits,
) -> Result[SessionStage, SessionError] {
  if self.attached && self.inflight.length() < limits.max_inflight {
    self.stage_inflight(message).map(delivery => SendNow(delivery))
  } else if self.pending.length() < limits.max_pending {
    self.pending.push(
      SessionMessage::new(message.topic, message.payload, message.retain),
    )
    Ok(Queued)
  } else {
    Err(PendingLimitReached(limits.max_pending))
  }
}

///|
fn ClientSession::promote_pending(
  self : ClientSession,
  limits : SessionLimits,
) -> Result[Array[SessionDelivery], SessionError] {
  let deliveries : Array[SessionDelivery] = []
  while self.attached &&
        self.inflight.length() < limits.max_inflight &&
        self.pending.length() > 0 {
    let message = self.pending[0]
    let remaining : Array[SessionMessage] = []
    for index in 1..<self.pending.length() {
      remaining.push(self.pending[index])
    }
    self.pending = remaining
    match self.stage_inflight(message) {
      Ok(delivery) => deliveries.push(delivery)
      Err(error) => return Err(error)
    }
  }
  Ok(deliveries)
}

///|
pub fn ClientSession::ack(
  self : ClientSession,
  packet_id : SessionPacketId,
  limits : SessionLimits,
) -> Result[SessionAck, SessionError] {
  let remaining : Array[OutboundInflight] = []
  let mut found = false
  for item in self.inflight {
    if !found && item.packet_id == packet_id {
      found = true
    } else {
      remaining.push(item)
    }
  }
  if !found {
    return Ok(UnknownPacketId)
  }
  self.inflight = remaining
  self.promote_pending(limits).map(promoted => Acknowledged(promoted))
}

///|
pub fn ClientSession::detach(self : ClientSession) -> Unit {
  self.attached = false
}

///|
pub fn ClientSession::attach(
  self : ClientSession,
  limits : SessionLimits,
) -> Result[Array[SessionDelivery], SessionError] {
  if self.attached {
    return Err(SessionAlreadyAttached)
  }
  self.attached = true
  let deliveries : Array[SessionDelivery] = []
  for item in self.inflight {
    deliveries.push({
      packet_id: item.packet_id,
      message: SessionMessage::new(
        item.message.topic,
        item.message.payload,
        item.message.retain,
      ),
      dup: true,
    })
  }
  match self.promote_pending(limits) {
    Ok(promoted) => deliveries.append(promoted)
    Err(error) => return Err(error)
  }
  Ok(deliveries)
}

///|
pub fn ClientSession::check_invariants(
  self : ClientSession,
  limits : SessionLimits,
) -> Result[Unit, SessionError] {
  if self.inflight.length() > limits.max_inflight {
    return Err(SessionInvariantViolation("inflight limit exceeded"))
  }
  if self.pending.length() > limits.max_pending {
    return Err(SessionInvariantViolation("pending limit exceeded"))
  }
  for index in 0..<self.inflight.length() {
    let item = self.inflight[index]
    if item.packet_id.value() < 1 || item.packet_id.value() > 65535 {
      return Err(SessionInvariantViolation("invalid inflight packet id"))
    }
    for other in (index + 1)..<self.inflight.length() {
      if self.inflight[other].packet_id == item.packet_id {
        return Err(SessionInvariantViolation("duplicate inflight packet id"))
      }
    }
  }
  Ok(())
}
