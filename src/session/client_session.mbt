///|
pub struct ClientSession {
  priv mut inflight_cost : Int64
  priv mut pending_cost : Int64
  client_id : ClientId
  mode : SessionMode
  mut attached : Bool
  allocator : PacketIdAllocator
  mut inflight : Array[OutboundInflight]
  mut pending : Array[SessionMessage]
  mut inbound_qos2 : Array[SessionPacketId]
  owner : @security.Principal
  mut detached_at_ms : Int64?
} derive(Eq, Debug)

///|
pub fn ClientSession::new(
  client_id : ClientId,
  mode? : SessionMode = Clean,
  attached? : Bool = true,
  owner? : @security.Principal = @security.Principal::Anonymous,
) -> ClientSession {
  {
    inflight_cost: 0L,
    pending_cost: 0L,
    client_id,
    mode,
    attached,
    allocator: PacketIdAllocator::new().unwrap(),
    inflight: [],
    pending: [],
    inbound_qos2: [],
    owner,
    detached_at_ms: if attached {
      None
    } else {
      Some(0L)
    },
  }
}

///|
pub fn ClientSession::restore(
  client_id : ClientId,
  next_packet_id : Int,
  inflight : Array[OutboundInflight],
  pending : Array[SessionMessage],
  owner? : @security.Principal = @security.Principal::Anonymous,
  detached_at_ms? : Int64 = 0L,
  inbound_qos2? : Array[SessionPacketId] = [],
) -> Result[ClientSession, SessionError] {
  let allocator = match PacketIdAllocator::new(next=next_packet_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let seen_inbound : Map[SessionPacketId, Bool] = Map([])
  for id in inbound_qos2 {
    if seen_inbound.contains(id) {
      return Err(
        SessionInvariantViolation("duplicate restored inbound packet id"),
      )
    }
    seen_inbound.set(id, true)
  }
  for message in pending {
    if message.qos == QoS0 {
      return Err(SessionInvariantViolation("restored pending QoS 0"))
    }
  }
  let stored_inflight : Array[OutboundInflight] = []
  for item in inflight {
    match (item.phase, item.message) {
      (AwaitPuback, Some({ qos: QoS1, .. })) => ()
      (AwaitPubrec, Some({ qos: QoS2, .. })) => ()
      (AwaitPubcomp, None) => ()
      _ =>
        return Err(
          SessionInvariantViolation("restored inflight phase/message mismatch"),
        )
    }
    if stored_inflight.any(existing => existing.packet_id == item.packet_id) {
      return Err(
        SessionInvariantViolation("duplicate restored inflight packet id"),
      )
    }
    stored_inflight.push(item.copy())
  }
  let stored_pending = pending.map(message => message.copy())
  let mut inflight_cost = 0L
  for item in stored_inflight {
    inflight_cost = @budget.checked_add(inflight_cost, item.cost()).unwrap()
  }
  let mut pending_cost = 0L
  for item in stored_pending {
    pending_cost = @budget.checked_add(pending_cost, item.cost()).unwrap()
  }
  Ok({
    inflight_cost,
    pending_cost,
    client_id,
    mode: Persistent,
    attached: false,
    allocator,
    inflight: stored_inflight,
    pending: stored_pending,
    inbound_qos2: inbound_qos2.copy(),
    owner,
    detached_at_ms: Some(detached_at_ms),
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
  self.inflight.map(item => item.copy())
}

///|
pub fn ClientSession::pending(self : ClientSession) -> Array[SessionMessage] {
  self.pending.map(message => message.copy())
}

///|
pub fn ClientSession::owner(self : ClientSession) -> @security.Principal {
  self.owner
}

///|
pub fn ClientSession::detached_at_ms(self : ClientSession) -> Int64? {
  self.detached_at_ms
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
  let phase = if message.qos == QoS2 { AwaitPubrec } else { AwaitPuback }
  self.inflight.push({ packet_id, message: Some(message.copy()), phase })
  self.inflight_cost += message.cost()
  Ok({ packet_id, message: Some(message.copy()), dup: false })
}

///|
pub fn ClientSession::stage(
  self : ClientSession,
  message : SessionMessage,
  limits : SessionLimits,
) -> Result[SessionStage, SessionError] {
  if message.qos == QoS0 {
    return Err(SessionInvariantViolation("queued message must use QoS 1 or 2"))
  }
  let cost = message.cost()
  if cost > limits.max_inflight_bytes ||
    cost > limits.max_state_bytes - self.state_bytes() {
    return Err(ByteLimitReached)
  }
  if self.attached &&
    self.pending.is_empty() &&
    self.inflight.length() < limits.max_inflight &&
    cost <= limits.max_inflight_bytes - self.inflight_bytes() {
    self.stage_inflight(message).map(delivery => SendNow(delivery))
  } else if self.pending.length() < limits.max_pending &&
    cost <= limits.max_pending_bytes - self.pending_bytes() {
    self.pending.push(message.copy())
    self.pending_cost += cost
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
    if message.cost() > limits.max_inflight_bytes - self.inflight_bytes() {
      break
    }
    let remaining : Array[SessionMessage] = []
    for index in 1..<self.pending.length() {
      remaining.push(self.pending[index])
    }
    match self.stage_inflight(message) {
      Ok(delivery) => {
        self.pending = remaining
        self.pending_cost -= message.cost()
        deliveries.push(delivery)
      }
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
  pubcomp? : Bool = false,
) -> Result[SessionAck, SessionError] {
  let remaining : Array[OutboundInflight] = []
  let mut released_cost = 0L
  let mut found = false
  for item in self.inflight {
    if !found && item.packet_id == packet_id {
      let expected = if pubcomp { AwaitPubcomp } else { AwaitPuback }
      if item.phase != expected {
        return Err(InvalidAcknowledgement)
      }
      found = true
      released_cost = item.cost()
    } else {
      remaining.push(item)
    }
  }
  if !found {
    return Ok(UnknownPacketId)
  }
  self.inflight = remaining
  self.inflight_cost -= released_cost
  self.promote_pending(limits).map(promoted => Acknowledged(promoted))
}

///|
pub fn ClientSession::detach(
  self : ClientSession,
  detached_at_ms? : Int64 = 0L,
) -> Unit {
  self.attached = false
  self.detached_at_ms = Some(detached_at_ms)
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
  self.detached_at_ms = None
  let deliveries : Array[SessionDelivery] = []
  for item in self.inflight {
    deliveries.push({
      packet_id: item.packet_id,
      message: item.message.map(message => message.copy()),
      dup: item.phase != AwaitPubcomp,
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
  if self.inflight_bytes() > limits.max_inflight_bytes ||
    self.pending_bytes() > limits.max_pending_bytes ||
    self.state_bytes() > limits.max_state_bytes {
    return Err(ByteLimitReached)
  }
  if self.inflight.length() > limits.max_inflight {
    return Err(SessionInvariantViolation("inflight limit exceeded"))
  }
  if self.pending.length() > limits.max_pending {
    return Err(SessionInvariantViolation("pending limit exceeded"))
  }
  if self.inbound_qos2.length() > limits.max_inbound_qos2 {
    return Err(SessionInvariantViolation("inbound QoS 2 limit exceeded"))
  }
  let seen_inbound : Map[SessionPacketId, Bool] = Map([])
  for id in self.inbound_qos2 {
    if seen_inbound.contains(id) {
      return Err(SessionInvariantViolation("duplicate inbound packet id"))
    }
    seen_inbound.set(id, true)
  }
  for message in self.pending {
    if message.qos == QoS0 {
      return Err(SessionInvariantViolation("pending QoS 0"))
    }
  }
  for index in 0..<self.inflight.length() {
    let item = self.inflight[index]
    match (item.phase, item.message) {
      (AwaitPuback, Some({ qos: QoS1, .. })) => ()
      (AwaitPubrec, Some({ qos: QoS2, .. })) => ()
      (AwaitPubcomp, None) => ()
      _ =>
        return Err(SessionInvariantViolation("inflight phase/message mismatch"))
    }
    if item.packet_id.value() < 1 || item.packet_id.value() > 65535 {
      return Err(SessionInvariantViolation("invalid inflight packet id"))
    }
    for other in (index + 1)..<self.inflight.length() {
      if self.inflight[other].packet_id == item.packet_id {
        return Err(SessionInvariantViolation("duplicate inflight packet id"))
      }
    }
  }
  let mut actual_inflight = 0L
  for item in self.inflight {
    actual_inflight += item.cost()
  }
  let mut actual_pending = 0L
  for item in self.pending {
    actual_pending += item.cost()
  }
  if actual_inflight != self.inflight_cost ||
    actual_pending != self.pending_cost {
    return Err(
      SessionInvariantViolation(
        "cached byte costs disagree with owned messages",
      ),
    )
  }
  Ok(())
}

///|
pub fn ClientSession::inbound_qos2(
  self : ClientSession,
) -> Array[SessionPacketId] {
  self.inbound_qos2.copy()
}

///|
pub fn ClientSession::inbound_qos2_count(self : ClientSession) -> Int {
  self.inbound_qos2.length()
}

///|
pub fn ClientSession::has_inbound_qos2(
  self : ClientSession,
  id : SessionPacketId,
) -> Bool {
  self.inbound_qos2.contains(id)
}

///|
pub fn ClientSession::begin_inbound_qos2(
  self : ClientSession,
  id : SessionPacketId,
  limits : SessionLimits,
) -> Result[Bool, SessionError] {
  if self.has_inbound_qos2(id) {
    return Ok(false)
  }
  if self.inbound_qos2.length() >= limits.max_inbound_qos2 {
    return Err(InboundQoS2LimitReached(limits.max_inbound_qos2))
  }
  if @budget.qos2_metadata_cost() > limits.max_state_bytes - self.state_bytes() {
    return Err(ByteLimitReached)
  }
  self.inbound_qos2.push(id)
  Ok(true)
}

///|
pub fn ClientSession::complete_inbound_qos2(
  self : ClientSession,
  id : SessionPacketId,
) -> Bool {
  if !self.has_inbound_qos2(id) {
    return false
  }
  self.inbound_qos2 = self.inbound_qos2.filter(value => value != id)
  true
}

///|
/// Returns true only for the first PUBREC. Unknown IDs elicit a stateless PUBREL.
pub fn ClientSession::pubrec(
  self : ClientSession,
  id : SessionPacketId,
) -> Result[Bool, SessionError] {
  for item in self.inflight {
    if item.packet_id != id {
      continue
    }
    match item.phase {
      AwaitPuback => return Err(InvalidAcknowledgement)
      AwaitPubcomp => return Ok(false)
      AwaitPubrec => {
        // Move exactly once: preserve both required replay subsequences.
        self.inflight = self.inflight.filter(value => value.packet_id != id)
        self.inflight.push({ packet_id: id, phase: AwaitPubcomp, message: None })
        self.inflight_cost -= item.cost() - 64L
        return Ok(true)
      }
    }
  }
  Ok(false)
}

///|
/// Payload ownership exposed without cloning, for later byte-budget integration.
pub fn ClientSession::outbound_message_bytes(self : ClientSession) -> Int64 {
  let mut total = 0L
  for item in self.inflight {
    if item.message is Some(message) {
      total += @utf8.encode(message.topic.value()).length().to_int64() +
        message.payload.length().to_int64()
    }
  }
  for message in self.pending {
    total += @utf8.encode(message.topic.value()).length().to_int64() +
      message.payload.length().to_int64()
  }
  total
}

///|
pub fn ClientSession::phase_count(
  self : ClientSession,
  phase : OutboundPhase,
) -> Int {
  self.inflight.filter(item => item.phase == phase).length()
}

///|
/// An isolated copy used by the router's prepare/install transaction.
pub fn ClientSession::copy(self : ClientSession) -> ClientSession {
  {
    ..self,
    allocator: PacketIdAllocator::new(next=self.allocator.next()).unwrap(),
    inflight: self.inflight(),
    pending: self.pending(),
    inbound_qos2: self.inbound_qos2.copy(),
  }
}

///|
pub fn ClientSession::inflight_bytes(self : ClientSession) -> Int64 {
  self.inflight_cost
}

///|
pub fn ClientSession::pending_bytes(self : ClientSession) -> Int64 {
  self.pending_cost
}

///|
pub fn ClientSession::state_bytes(self : ClientSession) -> Int64 {
  @budget.checked_add(
    @budget.checked_add(self.inflight_bytes(), self.pending_bytes()).unwrap(),
    self.inbound_qos2.length().to_int64() * 64L,
  ).unwrap()
}

///|
/// Router schedules promotion after acknowledging, with a separately admitted byte window.
pub fn ClientSession::promote(
  self : ClientSession,
  limits : SessionLimits,
) -> Result[Array[SessionDelivery], SessionError] {
  self.promote_pending(limits)
}

///|
pub fn ClientSession::pending_head_cost(self : ClientSession) -> Int64? {
  if self.pending.is_empty() {
    None
  } else {
    Some(self.pending[0].cost())
  }
}

///|
/// A read-only head lookup avoids cloning the payload for an authorization
/// decision before pending-to-inflight promotion.
pub fn ClientSession::pending_head_topic(
  self : ClientSession,
) -> @topic.TopicName? {
  if self.pending.is_empty() {
    None
  } else {
    Some(self.pending[0].topic)
  }
}

///|
/// Read-only reference; the immutable payload is not cloned for policy checks.
pub fn ClientSession::pending_head_reference(
  self : ClientSession,
) -> SessionMessage? {
  if self.pending.is_empty() {
    None
  } else {
    Some(self.pending[0])
  }
}

///|
/// Prepare the shallow pointer tail before committing a WAL cleanup record.
pub fn ClientSession::pending_tail_for_policy(
  self : ClientSession,
) -> Array[SessionMessage] {
  if self.pending.is_empty() {
    []
  } else {
    self.pending[1:].to_owned()
  }
}

///|
pub fn ClientSession::discard_pending_head_prepared(
  self : ClientSession,
  expected : SessionMessage,
  remaining : Array[SessionMessage],
) -> Bool {
  if self.pending.is_empty() ||
    !physical_equal(self.pending[0], expected) ||
    remaining.length() + 1 != self.pending.length() {
    return false
  }
  self.pending = remaining
  self.pending_cost -= expected.cost()
  true
}
// @session.ClientSession exposes a bounded promotion step for the broker's
// durable prepare path; the caller invokes it on an isolated session copy.

///|
pub fn ClientSession::promote_for_commit(
  self : ClientSession,
  limits : SessionLimits,
) -> Result[Array[SessionDelivery], SessionError] {
  self.promote_pending(limits)
}

///|
pub fn ClientSession::inflight_item(
  self : ClientSession,
  index : Int,
) -> OutboundInflight? {
  if index < 0 || index >= self.inflight.length() {
    None
  } else {
    Some(self.inflight[index].copy())
  }
}

///|
pub fn ClientSession::pending_item(
  self : ClientSession,
  index : Int,
) -> SessionMessage? {
  if index < 0 || index >= self.pending.length() {
    None
  } else {
    Some(self.pending[index].copy())
  }
}

///|
pub fn ClientSession::inbound_qos2_item(
  self : ClientSession,
  index : Int,
) -> SessionPacketId? {
  if index < 0 || index >= self.inbound_qos2.length() {
    None
  } else {
    Some(self.inbound_qos2[index])
  }
}

///|
pub fn ClientSession::inflight_item_cost(
  self : ClientSession,
  index : Int,
) -> Int64? {
  if index < 0 || index >= self.inflight.length() {
    None
  } else {
    Some(self.inflight[index].cost())
  }
}

///|
pub fn ClientSession::pending_item_cost(
  self : ClientSession,
  index : Int,
) -> Int64? {
  if index < 0 || index >= self.pending.length() {
    None
  } else {
    Some(self.pending[index].cost())
  }
}
