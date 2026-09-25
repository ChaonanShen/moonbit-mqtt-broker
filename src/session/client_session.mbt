///|
pub struct ClientSession {
  priv mut inflight_cost : Int64
  priv mut pending_cost : Int64
  client_id : ClientId
  mode : SessionMode
  retention : Retention
  last_protocol : Int
  mut expiry_deadline : Deadline?
  mut attached : Bool
  allocator : PacketIdAllocator
  mut inflight : Array[OutboundInflight]
  mut pending : Array[SessionMessage]
  mut inbound_qos2 : Array[SessionPacketId]
  owner : @security.Principal
  mut detached_at_ms : Int64?
  priv mut policy_revision : Int64
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
    retention: if mode == Clean {
      DropOnClose
    } else {
      LegacyBrokerPolicy
    },
    expiry_deadline: None,
    last_protocol: 4,
    attached,
    allocator: PacketIdAllocator::new().unwrap(),
    inflight: [],
    pending: [],
    inbound_qos2: [],
    owner,
    policy_revision: 1L,
    detached_at_ms: if attached {
      None
    } else {
      Some(0L)
    },
  }
}

///|
pub fn ClientSession::new_with_retention(
  client_id : ClientId,
  retention : Retention,
  attached? : Bool = true,
  owner? : @security.Principal = @security.Principal::Anonymous,
) -> ClientSession {
  let mode = if retention == DropOnClose { Clean } else { Persistent }
  let session = ClientSession::new(client_id, mode~, attached~, owner~)
  { ..session, retention, last_protocol: 5 }
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
    retention: LegacyBrokerPolicy,
    expiry_deadline: None,
    last_protocol: 4,
    attached: false,
    allocator,
    inflight: stored_inflight,
    pending: stored_pending,
    inbound_qos2: inbound_qos2.copy(),
    owner,
    policy_revision: 1L,
    detached_at_ms: Some(detached_at_ms),
  })
}

///|
pub fn ClientSession::client_id(self : ClientSession) -> ClientId {
  self.client_id
}

///|
pub fn ClientSession::policy_revision(self : ClientSession) -> Int64 {
  self.policy_revision
}

///|
fn ClientSession::bump_policy_revision(self : ClientSession) -> Unit {
  if self.policy_revision == 9223372036854775807L {
    abort("Session policy revision exhausted")
  }
  self.policy_revision += 1L
}

///|
pub fn ClientSession::mode(self : ClientSession) -> SessionMode {
  self.mode
}

///|
pub fn ClientSession::retention(self : ClientSession) -> Retention {
  self.retention
}

///|
pub fn ClientSession::last_protocol(self : ClientSession) -> Int {
  self.last_protocol
}

///|
pub fn ClientSession::with_last_protocol(
  self : ClientSession,
  version : Int,
) -> ClientSession {
  { ..self, last_protocol: version }
}

///|
pub fn ClientSession::with_retention(
  self : ClientSession,
  retention : Retention,
) -> ClientSession {
  {
    ..self,
    mode: if retention == DropOnClose {
      Clean
    } else {
      Persistent
    },
    retention,
    last_protocol: 5,
    expiry_deadline: None,
  }
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
  self.inflight.push({
    packet_id,
    delivery_id: message.delivery_id,
    started: true,
    subscription_identifiers: message.subscription_identifiers.copy(),
    message: Some(message.copy()),
    phase,
  })
  self.inflight_cost += message.cost()
  self.bump_policy_revision()
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
    self.bump_policy_revision()
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
    if message.metadata.expiry is Some(deadline) &&
      deadline.remaining_at(@budget.monotonic_ms()) == 0L {
      self.pending = remaining
      self.pending_cost -= message.cost()
      self.bump_policy_revision()
      continue
    }
    if message.cost() > limits.max_inflight_bytes - self.inflight_bytes() {
      break
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
  self.bump_policy_revision()
  self.promote_pending(limits).map(promoted => Acknowledged(promoted))
}

///|
pub fn ClientSession::detach(
  self : ClientSession,
  detached_at_ms? : Int64 = 0L,
) -> Unit {
  self.attached = false
  self.detached_at_ms = Some(detached_at_ms)
  self.expiry_deadline = None
  self.bump_policy_revision()
}

///|
pub fn ClientSession::detach_v5(
  self : ClientSession,
  now_mono_ms : Int64,
  now_wall_ms : Int64,
) -> Result[Unit, RetentionError] {
  let deadline = match self.retention {
    FiniteV5(seconds) =>
      match Deadline::from_seconds(now_mono_ms, now_wall_ms, seconds) {
        Ok(value) => Some(value)
        Err(error) => return Err(error)
      }
    _ => None
  }
  self.detach(detached_at_ms=now_wall_ms)
  self.expiry_deadline = deadline
  Ok(())
}

///|
pub fn ClientSession::expiry_deadline(self : ClientSession) -> Deadline? {
  self.expiry_deadline
}

///|
pub fn ClientSession::logically_expired(
  self : ClientSession,
  now_mono_ms : Int64,
) -> Bool {
  if self.attached {
    return false
  }
  match self.retention {
    DropOnClose => true
    FiniteV5(_) =>
      match self.expiry_deadline {
        Some(deadline) => deadline.remaining_at(now_mono_ms) == 0L
        None => true
      }
    _ => false
  }
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
  self.expiry_deadline = None
  self.bump_policy_revision()
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
  self.bump_policy_revision()
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
  self.bump_policy_revision()
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
        let terminal : OutboundInflight = {
          packet_id: id,
          delivery_id: item.delivery_id,
          started: item.started,
          subscription_identifiers: item.subscription_identifiers.copy(),
          phase: AwaitPubcomp,
          message: None,
        }
        self.inflight.push(terminal)
        self.inflight_cost -= item.cost() - terminal.cost()
        self.bump_policy_revision()
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
  self.pending_item_reference(0)
}

///|
pub fn ClientSession::pending_item_reference(
  self : ClientSession,
  index : Int,
) -> SessionMessage? {
  if index < 0 || index >= self.pending.length() {
    None
  } else {
    Some(self.pending[index])
  }
}

///|
/// Prepare the shallow pointer tail before committing a WAL cleanup record.
pub fn ClientSession::pending_tail_for_policy(
  self : ClientSession,
) -> Array[SessionMessage] {
  self.pending_without_item_for_policy(0)
}

///|
pub fn ClientSession::pending_without_item_for_policy(
  self : ClientSession,
  index : Int,
) -> Array[SessionMessage] {
  let remaining : Array[SessionMessage] = []
  for position in 0..<self.pending.length() {
    if position != index {
      remaining.push(self.pending[position])
    }
  }
  remaining
}

///|
pub fn ClientSession::discard_pending_head_prepared(
  self : ClientSession,
  expected : SessionMessage,
  remaining : Array[SessionMessage],
) -> Bool {
  self.discard_pending_item_prepared(0, expected, remaining)
}

///|
pub fn ClientSession::discard_pending_item_prepared(
  self : ClientSession,
  index : Int,
  expected : SessionMessage,
  remaining : Array[SessionMessage],
) -> Bool {
  if index < 0 ||
    index >= self.pending.length() ||
    !physical_equal(self.pending[index], expected) ||
    remaining.length() + 1 != self.pending.length() {
    return false
  }
  self.pending = remaining
  self.pending_cost -= expected.cost()
  self.bump_policy_revision()
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
/// Read-only reference for one bounded policy scan step.
pub fn ClientSession::inflight_item_reference(
  self : ClientSession,
  index : Int,
) -> OutboundInflight? {
  if index < 0 || index >= self.inflight.length() {
    None
  } else {
    Some(self.inflight[index])
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

///|
pub fn ClientSession::restore_v5(
  client_id : ClientId,
  next_packet_id : Int,
  inflight : Array[OutboundInflight],
  pending : Array[SessionMessage],
  owner : @security.Principal,
  detached_at_ms : Int64,
  inbound_qos2 : Array[SessionPacketId],
  retention : Retention,
  last_protocol : Int,
  state_revision : Int64,
  expiry_deadline : Deadline?,
) -> Result[ClientSession, SessionError] {
  if retention == DropOnClose ||
    state_revision < 1L ||
    (last_protocol != 4 && last_protocol != 5) {
    return Err(
      SessionInvariantViolation("invalid durable V5 session retention"),
    )
  }
  if retention is FiniteV5(_) && expiry_deadline is None {
    return Err(SessionInvariantViolation("finite V5 session lacks deadline"))
  }
  let restored = match
    ClientSession::restore(
      client_id,
      next_packet_id,
      inflight,
      pending,
      owner~,
      detached_at_ms~,
      inbound_qos2~,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    ..restored,
    retention,
    last_protocol,
    expiry_deadline,
    policy_revision: state_revision,
  })
}

///|
pub fn ClientSession::materialize_delivery_ids(
  self : ClientSession,
  first_id : Int64,
) -> Result[Int64, SessionError] {
  if first_id < 1L {
    return Err(SessionInvariantViolation("invalid delivery floor"))
  }
  let mut next = first_id
  for index in 0..<self.inflight.length() {
    let item = self.inflight[index]
    if item.delivery_id == 0L {
      if next == 9223372036854775807L {
        return Err(SessionInvariantViolation("delivery identity exhausted"))
      }
      let message = item.message.map(value => { ..value, delivery_id: next })
      self.inflight[index] = { ..item, delivery_id: next, message }
      next += 1L
    } else if item.delivery_id >= next {
      if item.delivery_id == 9223372036854775807L {
        return Err(SessionInvariantViolation("delivery identity exhausted"))
      }
      next = item.delivery_id + 1L
    }
  }
  for index in 0..<self.pending.length() {
    let item = self.pending[index]
    if item.delivery_id == 0L {
      if next == 9223372036854775807L {
        return Err(SessionInvariantViolation("delivery identity exhausted"))
      }
      self.pending[index] = { ..item, delivery_id: next }
      next += 1L
    } else if item.delivery_id >= next {
      if item.delivery_id == 9223372036854775807L {
        return Err(SessionInvariantViolation("delivery identity exhausted"))
      }
      next = item.delivery_id + 1L
    }
  }
  Ok(next)
}

///|
pub fn ClientSession::subscription_changed(self : ClientSession) -> Unit {
  self.bump_policy_revision()
}
