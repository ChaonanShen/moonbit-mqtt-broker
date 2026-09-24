///|
pub struct BrokerState {
  priv mut action_scope : Bool
  priv action_leases : Array[@budget.Ticket]
  priv mut promotion_cursor : Int
  priv resources : RouterResources
  config : BrokerConfig
  priv mut security_policy : @security.SecurityPolicy?
  priv sessions : Map[@session.ClientId, @session.ClientSession]
  priv mut policy_slots : @slot_index.SlotIndex?
  priv mut policy_incarnations : Map[@session.ClientId, Int64]?
  priv mut next_policy_incarnation : Int64
  priv mut policy_index_ticket : @budget.Ticket?
  priv mut admin_sessions : AdminSessionIndex?
  priv subscriptions : SubscriptionIndex
  priv retained : RetainedStore
  priv mut inflight_total : Int
  priv mut pending_qos1_total : Int
  priv mut inbound_qos2_total : Int
  priv mut snapshot_revision : Int64
  priv mut last_expiration_check_ms : Int64?
  priv mut time_regression_reported : Bool
}

///|
enum DeliveryDestination {
  DirectQoS0
  StageInflight
  StagePending
  DropResource(LimitKind)
} derive(Eq, Debug)

///|
priv struct DeliveryCandidate {
  recipient : @session.ClientId
  topic : @topic.TopicName
  payload : Bytes
  qos : @session.DeliveryQoS
  retain : Bool
}

///|
priv struct PlannedDelivery {
  candidate : DeliveryCandidate
  destination : DeliveryDestination
}

///|
priv struct ExpirationCandidate {
  client_id : @session.ClientId
  detached_at_ms : Int64
}

///|
fn copy_router_bytes(payload : Bytes) -> Bytes {
  Bytes::from_array(payload.to_array())
}

///|
pub fn BrokerState::new(
  config : BrokerConfig,
  ledger? : @budget.Ledger,
) -> BrokerState {
  {
    config,
    security_policy: None,
    action_scope: false,
    action_leases: [],
    promotion_cursor: 0,
    resources: RouterResources::new(config.resources, ledger?),
    sessions: Map([]),
    policy_slots: None,
    policy_incarnations: None,
    next_policy_incarnation: 1L,
    policy_index_ticket: None,
    admin_sessions: None,
    subscriptions: SubscriptionIndex::new(),
    retained: RetainedStore::new(),
    inflight_total: 0,
    pending_qos1_total: 0,
    inbound_qos2_total: 0,
    snapshot_revision: 0L,
    last_expiration_check_ms: None,
    time_regression_reported: false,
  }
}

///|
pub fn BrokerState::config(self : BrokerState) -> BrokerConfig {
  self.config
}

///|
/// A prepared generation is installed only outside a router action scope.
pub fn BrokerState::set_security_policy(
  self : BrokerState,
  policy : @security.SecurityPolicy,
) -> Bool {
  if self.action_scope {
    return false
  }
  self.security_policy = Some(policy)
  true
}

///|
pub fn BrokerState::session_count(self : BrokerState) -> Int {
  self.sessions.length()
}

///|
/// This source-of-truth index is allocated only for reload-enabled service.
/// Startup restoration may scan the initial sessions before listeners bind.
pub fn BrokerState::enable_policy_index(
  self : BrokerState,
) -> Result[Unit, RouterError] {
  if self.policy_slots is Some(_) {
    return Ok(())
  }
  let capacity = self.config.max_sessions()
  let session_cost = @budget.checked_mul(capacity.to_int64(), 128L)
  let subscription_cost = @budget.checked_mul(
    self.config.max_subscriptions_total().to_int64(),
    160L,
  )
  let cost = match (session_cost, subscription_cost) {
    (Ok(a), Ok(b)) =>
      match @budget.checked_add(a, b) {
        Ok(total) => @budget.checked_add(total, 4096L).unwrap_or(-1L)
        Err(_) => -1L
      }
    _ => -1L
  }
  if cost < 0L {
    return Err(InvalidConfiguration("policy index capacity overflow"))
  }
  let pool = self.resources.ledger
    .pool(Infrastructure, self.config.resources.get("max_managed_bytes_total"))
    .unwrap()
  let ticket = match pool.reserve(cost) {
    Ok(value) => value
    Err(error) => return Err(ByteResourceLimit(error))
  }
  let slots = @slot_index.SlotIndex::new(capacity)
  let incarnations : Map[@session.ClientId, Int64] = Map([])
  let mut next_incarnation = 1L
  for id, _ in self.sessions {
    match slots.put(id.value()) {
      @slot_index.Added(_) => {
        incarnations.set(id, next_incarnation)
        next_incarnation += 1L
      }
      _ => {
        ticket.release().unwrap()
        return Err(InvariantViolation("policy index startup identity"))
      }
    }
  }
  if !self.subscriptions.enable_policy_slots(
      self.config.max_subscriptions_total(),
    ) {
    ticket.release().unwrap()
    return Err(InvariantViolation("policy subscription index startup"))
  }
  ticket.commit().unwrap()
  self.policy_index_ticket = Some(ticket)
  self.policy_incarnations = Some(incarnations)
  self.next_policy_incarnation = next_incarnation
  self.policy_slots = Some(slots)
  Ok(())
}

///|
fn BrokerState::track_policy_session(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Unit {
  if self.policy_slots is Some(slots) {
    match slots.put(client_id.value()) {
      @slot_index.Added(_) => {
        if self.next_policy_incarnation == 9223372036854775807L {
          abort("core session incarnation exhausted")
        }
        self.policy_incarnations
        .unwrap()
        .set(client_id, self.next_policy_incarnation)
        self.next_policy_incarnation += 1L
      }
      @slot_index.Existing(_) => ()
      @slot_index.Full => abort("core session slot capacity exceeded")
    }
  }
}

///|
fn BrokerState::untrack_policy_session(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Unit {
  if self.policy_slots is Some(slots) {
    if !slots.remove(client_id.value()) {
      abort("core session slot identity missing")
    }
    self.policy_incarnations.unwrap().remove(client_id)
  }
}

///|
fn BrokerState::replace_policy_session(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Unit {
  if self.policy_incarnations is Some(incarnations) {
    if self.next_policy_incarnation == 9223372036854775807L ||
      !incarnations.contains(client_id) {
      abort("core session replacement identity invalid")
    }
    incarnations.set(client_id, self.next_policy_incarnation)
    self.next_policy_incarnation += 1L
  }
}

///|
pub fn BrokerState::policy_session_incarnation(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Int64? {
  match self.policy_incarnations {
    Some(value) => value.get(client_id)
    None => None
  }
}

///|
pub fn BrokerState::policy_session_revision(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Int64? {
  self.sessions.get(client_id).map(session => session.policy_revision())
}

///|
/// A page scans at most scan_limit physical slots, including empty slots.
pub fn BrokerState::policy_session_page(
  self : BrokerState,
  start : Int,
  scan_limit : Int,
) -> @slot_index.SlotPage? {
  self.policy_slots.map(slots => {
    slots.page(start, scan_limit, scan_limit, _ => true)
  })
}

///|
pub fn BrokerState::policy_subscription_page(
  self : BrokerState,
  start : Int,
  scan_limit : Int,
) -> PolicySubscriptionPage? {
  self.subscriptions.policy_page(start, scan_limit)
}

///|
pub fn BrokerState::policy_subscription_identity(
  self : BrokerState,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
) -> Int64? {
  self.subscriptions.policy_identity(client_id, filter)
}

///|
pub fn BrokerState::subscription_count(self : BrokerState) -> Int {
  self.subscriptions.subscription_count()
}

///|
pub fn BrokerState::retained_count(self : BrokerState) -> Int {
  self.retained.count()
}

///|
pub fn BrokerState::inflight_count(self : BrokerState) -> Int {
  self.inflight_total
}

///|
pub fn BrokerState::pending_qos1_count(self : BrokerState) -> Int {
  self.pending_qos1_total
}

///|
pub fn BrokerState::snapshot_revision(self : BrokerState) -> Int64 {
  self.snapshot_revision
}

///|
fn BrokerState::mark_snapshot_dirty(self : BrokerState) -> Unit {
  self.snapshot_revision = self.snapshot_revision + 1L
}

///|
pub fn BrokerState::attached_session_count(self : BrokerState) -> Int {
  let mut count = 0
  for _, session in self.sessions {
    if session.is_attached() {
      count = count + 1
    }
  }
  count
}

///|
pub fn BrokerState::has_session(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Bool {
  self.sessions.get(client_id) is Some(_)
}

///|
pub fn BrokerState::session_mode(
  self : BrokerState,
  client_id : @session.ClientId,
) -> @session.SessionMode? {
  self.sessions.get(client_id).map(session => session.mode())
}

///|
pub fn BrokerState::session_attached(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Bool? {
  self.sessions.get(client_id).map(session => session.is_attached())
}

///|
pub fn BrokerState::session_owner(
  self : BrokerState,
  client_id : @session.ClientId,
) -> @security.Principal? {
  self.sessions.get(client_id).map(session => session.owner())
}

///|
pub fn BrokerState::session_detached_at_ms(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Int64? {
  match self.sessions.get(client_id) {
    Some(session) => session.detached_at_ms()
    None => None
  }
}

///|
pub fn BrokerState::session_inflight_count(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Int? {
  self.sessions.get(client_id).map(session => session.inflight_count())
}

///|
pub fn BrokerState::session_pending_count(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Int? {
  self.sessions.get(client_id).map(session => session.pending_count())
}

///|
pub fn BrokerState::subscription_qos(
  self : BrokerState,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
) -> @session.DeliveryQoS? {
  self.subscriptions.qos(client_id, filter)
}

///|
pub fn BrokerState::retained_message(
  self : BrokerState,
  topic : @topic.TopicName,
) -> RetainedMessage? {
  self.retained.get(topic)
}

///|
/// Read-only subscriber lookup for internal QoS 0 system publications.
pub fn BrokerState::system_subscribers(
  self : BrokerState,
  topic : @topic.TopicName,
) -> Array[@session.ClientId] {
  self.subscriptions.matches(topic).map(item => item.client_id)
}

///|
fn BrokerState::session_limits(
  self : BrokerState,
  max_inflight? : Int,
  max_pending? : Int,
) -> @session.SessionLimits {
  @session.SessionLimits::new(
    max_inflight.unwrap_or(self.config.max_inflight_per_session()),
    max_pending.unwrap_or(self.config.max_pending_qos1_per_session()),
    max_inbound_qos2=self.config.max_inbound_qos2_per_session(),
    max_inflight_bytes=self.config.resources.get(
      "max_inflight_bytes_per_session",
    ),
    max_pending_bytes=self.config.resources.get("max_pending_bytes_per_session"),
    max_state_bytes=self.config.resources.get("max_session_state_bytes"),
  ).unwrap()
}

///|
fn BrokerState::create_session(
  self : BrokerState,
  request : CreateOwnedSessionRequest,
) -> Result[Array[BrokerAction], RouterError] {
  if self.sessions.get(request.client_id) is Some(_) {
    return Err(SessionAlreadyExists(request.client_id))
  }
  if self.sessions.length() >= self.config.max_sessions() {
    return Err(SessionLimitReached(self.config.max_sessions()))
  }
  if self.security_policy is Some(policy) &&
    !policy.allows_principal(request.owner) {
    return Err(InvalidSessionState(request.client_id))
  }
  match
    self.resources.add_owner(request.client_id, {
      inflight: 0L,
      pending: 0L,
      inbound: 0L,
      subscriptions: 0L,
      metadata: @budget.identity_cost(
        request.client_id.value(),
        request.owner.storage_value(),
      ),
    }) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  self.track_policy_session(request.client_id)
  self.sessions.set(
    request.client_id,
    @session.ClientSession::new(
      request.client_id,
      mode=request.mode,
      attached=request.attached,
      owner=request.owner,
    ),
  )
  if self.admin_sessions is Some(index) {
    index.register(request.client_id)
  }
  if request.mode == @session.SessionMode::Persistent {
    self.mark_snapshot_dirty()
  }
  Ok([SessionCreated(request.client_id)])
}

///|
fn BrokerState::remove_session(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Result[Array[BrokerAction], RouterError] {
  let session = match self.sessions.get(client_id) {
    None => return Err(SessionNotFound(client_id))
    Some(value) => value
  }
  self.inbound_qos2_total -= session.inbound_qos2_count()
  self.inflight_total = self.inflight_total - session.inflight_count()
  self.pending_qos1_total = self.pending_qos1_total - session.pending_count()
  if self.admin_sessions is Some(index) {
    index.remove_all_subscriptions(client_id)
  }
  ignore(self.subscriptions.remove_all(client_id))
  self.sessions.remove(client_id)
  self.untrack_policy_session(client_id)
  if self.admin_sessions is Some(index) {
    index.remove(client_id)
  }
  if session.mode() == @session.SessionMode::Persistent {
    self.mark_snapshot_dirty()
  }
  Ok([SessionRemoved(client_id)])
}

///|
fn BrokerState::expire_sessions(
  self : BrokerState,
  now_ms : Int64,
) -> Result[Array[BrokerAction], RouterError] {
  let expiry_ms = match self.config.persistent_session_expiry_ms() {
    None => return Ok([])
    Some(value) => value
  }
  match self.last_expiration_check_ms {
    Some(previous) if now_ms < previous => {
      if self.time_regression_reported {
        return Ok([])
      }
      self.time_regression_reported = true
      return Ok([TimeRegressionDetected(previous, now_ms)])
    }
    _ => ()
  }
  self.last_expiration_check_ms = Some(now_ms)
  self.time_regression_reported = false
  let candidates : Array[ExpirationCandidate] = []
  for client_id, session in self.sessions {
    if session.mode() != @session.SessionMode::Persistent ||
      session.is_attached() {
      continue
    }
    let detached_at_ms = session.detached_at_ms().unwrap_or(0L)
    if detached_at_ms == 0L {
      // V1 and crash-time active snapshots have no trustworthy detach epoch.
      // Start their full expiry window on first observation after recovery.
      session.detach(detached_at_ms=now_ms)
      self.mark_snapshot_dirty()
    } else if now_ms >= detached_at_ms && now_ms - detached_at_ms >= expiry_ms {
      candidates.push({ client_id, detached_at_ms })
    }
  }
  candidates.sort_by(fn(left, right) {
    if left.detached_at_ms < right.detached_at_ms {
      -1
    } else if left.detached_at_ms > right.detached_at_ms {
      1
    } else {
      compare_utf8_for_sort(left.client_id.value(), right.client_id.value())
    }
  })
  let actions : Array[BrokerAction] = []
  let limit = self.config.max_session_expirations_per_tick()
  for index in 0..<@cmp.minimum(limit, candidates.length()) {
    let client_id = candidates[index].client_id
    match self.remove_session(client_id) {
      Ok(removed) => {
        actions.append(removed)
        actions.push(SessionExpired(client_id))
      }
      Err(error) => return Err(error)
    }
  }
  Ok(actions)
}

///|
fn BrokerState::planned_changes_snapshot(
  self : BrokerState,
  planned : Array[PlannedDelivery],
) -> Bool {
  planned.any(item => {
    match item.destination {
      StageInflight | StagePending =>
        self.session_is_persistent(item.candidate.recipient)
      _ => false
    }
  })
}

///|
fn BrokerState::session_is_persistent(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Bool {
  match self.sessions.get(client_id) {
    Some(session) => session.mode() == @session.SessionMode::Persistent
    None => false
  }
}

///|
fn BrokerState::pending_head_authorized(
  self : BrokerState,
  session : @session.ClientSession,
) -> Bool {
  match self.security_policy {
    None => true
    Some(policy) => {
      let principal = session.owner()
      if !policy.allows_principal(principal) {
        return false
      }
      match session.pending_head_topic() {
        Some(topic) => policy.can_read_topic(principal, topic)
        None => true
      }
    }
  }
}

///|
fn BrokerState::delivery_candidates(
  self : BrokerState,
  input : PublishInput,
  retain : Bool,
) -> Array[DeliveryCandidate] {
  let candidates : Array[DeliveryCandidate] = []
  for subscription in self.subscriptions.matches(input.topic) {
    if self.security_policy is Some(policy) &&
      self.session_owner(subscription.client_id) is Some(owner) &&
      (
        !policy.allows_principal(owner) ||
        !policy.can_read_topic(owner, input.topic)
      ) {
      continue
    }
    candidates.push({
      recipient: subscription.client_id,
      topic: input.topic,
      payload: input.payload,
      qos: @session.min_qos(input.qos, subscription.qos),
      retain,
    })
  }
  candidates
}

///|
fn BrokerState::preflight_deliveries(
  self : BrokerState,
  candidates : Array[DeliveryCandidate],
  strict : Bool,
  retained_delta? : Int64 = 0L,
) -> Result[Array[PlannedDelivery], RouterError] {
  let planned : Array[PlannedDelivery] = []
  let planned_inflight : Map[@session.ClientId, Int] = Map([])
  let planned_pending : Map[@session.ClientId, Int] = Map([])
  let mut inflight_added = 0
  let mut pending_added = 0
  let planned_inflight_bytes : Map[@session.ClientId, Int64] = Map([])
  let planned_pending_bytes : Map[@session.ClientId, Int64] = Map([])
  let mut inflight_bytes_added = 0L
  let mut pending_bytes_added = 0L
  for candidate in candidates {
    let session = match self.sessions.get(candidate.recipient) {
      Some(value) => value
      None =>
        return Err(
          InvariantViolation("subscription references missing session"),
        )
    }
    match candidate.qos {
      QoS0 =>
        if session.is_attached() {
          planned.push({ candidate, destination: DirectQoS0 })
        }
      QoS1 | QoS2 => {
        let extra_inflight = planned_inflight
          .get(candidate.recipient)
          .unwrap_or(0)
        let extra_pending = planned_pending
          .get(candidate.recipient)
          .unwrap_or(0)
        let cost = @budget.message_cost(
          candidate.topic.value(),
          candidate.payload.length().to_int64(),
        ).unwrap()
        let usage = self.resources.owners.get(candidate.recipient).unwrap().usage
        let inflight_extra = planned_inflight_bytes
          .get(candidate.recipient)
          .unwrap_or(0L)
        let pending_extra = planned_pending_bytes
          .get(candidate.recipient)
          .unwrap_or(0L)
        let limits = self.config.resources
        let state_free = limits.get("max_session_state_bytes") -
          usage.inflight -
          usage.pending -
          usage.inbound -
          inflight_extra -
          pending_extra
        let available = self.resources.ledger.ordinary_available()
        let adjusted_free = if retained_delta >= 0L {
          match @budget.checked_sub(available, retained_delta) {
            Ok(value) => value
            Err(_) => 0L
          }
        } else {
          match @budget.checked_add(available, -retained_delta) {
            Ok(value) => value
            Err(_) => 0L
          }
        }
        let global_free_bytes = adjusted_free -
          inflight_bytes_added -
          pending_bytes_added
        let inflight_fits = cost <=
          limits.get("max_inflight_bytes_per_session") -
          usage.inflight -
          inflight_extra &&
          cost <=
          limits.get("max_inflight_bytes_total") -
          self.inflight_bytes() -
          inflight_bytes_added
        let pending_fits = cost <=
          limits.get("max_pending_bytes_per_session") -
          usage.pending -
          pending_extra &&
          cost <=
          limits.get("max_pending_bytes_total") -
          self.pending_bytes() -
          pending_bytes_added
        if cost > state_free ||
          cost > global_free_bytes ||
          cost > limits.get("max_inflight_bytes_per_session") {
          if strict {
            return Err(QoS1ResourceLimit(candidate.recipient, Bytes))
          }
          planned.push({ candidate, destination: DropResource(Bytes) })
          continue
        }
        let session_inflight = session.inflight_count() + extra_inflight
        let session_pending = session.pending_count() + extra_pending
        if session.is_attached() &&
          session_pending == 0 &&
          inflight_fits &&
          session_inflight < self.config.max_inflight_per_session() &&
          self.inflight_total + inflight_added <
          self.config.max_inflight_total() {
          planned_inflight.set(candidate.recipient, extra_inflight + 1)
          inflight_added = inflight_added + 1
          inflight_bytes_added += cost
          planned_inflight_bytes.set(candidate.recipient, inflight_extra + cost)
          planned.push({ candidate, destination: StageInflight })
        } else if pending_fits &&
          session_pending < self.config.max_pending_qos1_per_session() &&
          self.pending_qos1_total + pending_added <
          self.config.max_pending_qos1_total() {
          planned_pending.set(candidate.recipient, extra_pending + 1)
          pending_added = pending_added + 1
          pending_bytes_added += cost
          planned_pending_bytes.set(candidate.recipient, pending_extra + cost)
          planned.push({ candidate, destination: StagePending })
        } else {
          let limit = if session_pending >=
            self.config.max_pending_qos1_per_session() {
            PendingQoS1PerSession
          } else {
            PendingQoS1Total
          }
          if strict {
            return Err(QoS1ResourceLimit(candidate.recipient, limit))
          }
          planned.push({ candidate, destination: DropResource(limit) })
        }
      }
    }
  }
  Ok(planned)
}

///|
fn BrokerState::prepare_deliveries(
  self : BrokerState,
  planned : Array[PlannedDelivery],
  deferred? : Bool = false,
) -> Result[PreparedDeliveries, RouterError] {
  let usage_updates : Map[@session.ClientId, ResourceUsage] = Map([])
  let copied : Map[@session.ClientId, Bool] = Map([])
  let mut scratch_bytes = planned.length().to_int64() * 128L
  for item in planned {
    let candidate = item.candidate
    let cost = @budget.message_cost(
      candidate.topic.value(),
      candidate.payload.length().to_int64(),
    ).unwrap()
    match item.destination {
      DirectQoS0 =>
        scratch_bytes = @budget.checked_add(
          scratch_bytes,
          @budget.checked_mul(cost, 3L).unwrap(),
        ).unwrap()
      StageInflight | StagePending => {
        let id = candidate.recipient
        let usage = usage_updates
          .get(id)
          .unwrap_or(self.resources.owners.get(id).unwrap().usage)
        if !copied.contains(id) {
          scratch_bytes = @budget.checked_add(
            scratch_bytes,
            @budget.checked_mul(
              self.sessions.get(id).unwrap().state_bytes(),
              2L,
            ).unwrap(),
          ).unwrap()
          copied.set(id, true)
        }
        scratch_bytes = @budget.checked_add(
          scratch_bytes,
          @budget.checked_mul(cost, 6L).unwrap(),
        ).unwrap()
        usage_updates.set(
          id,
          match item.destination {
            StageInflight => { ..usage, inflight: usage.inflight + cost }
            _ => { ..usage, pending: usage.pending + cost }
          },
        )
      }
      DropResource(_) => ()
    }
  }
  let scratch = match self.reserve_scratch(scratch_bytes) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  if !deferred {
    match self.resources.set_usages(usage_updates) {
      Err(error) => {
        scratch.release().unwrap()
        return Err(error)
      }
      Ok(_) => ()
    }
  }
  let mut prepared_ok = false
  defer (if !prepared_ok { scratch.release().unwrap() })
  let actions : Array[BrokerAction] = []
  let updates : Map[@session.ClientId, @session.ClientSession] = Map([])
  let mut inflight_added = 0
  let mut pending_added = 0
  for item in planned {
    let candidate = item.candidate
    match item.destination {
      DirectQoS0 =>
        actions.push(
          Deliver({
            recipient: candidate.recipient,
            topic: candidate.topic,
            payload: copy_router_bytes(candidate.payload),
            qos: QoS0,
            retain: candidate.retain,
            packet_id: None,
            dup: false,
          }),
        )
      StageInflight | StagePending => {
        let session = match updates.get(candidate.recipient) {
          Some(value) => value
          None => {
            let value = self.sessions.get(candidate.recipient).unwrap().copy()
            updates.set(candidate.recipient, value)
            value
          }
        }
        let max_inflight = match item.destination {
          StageInflight => session.inflight_count() + 1
          _ => session.inflight_count()
        }
        let max_pending = match item.destination {
          StagePending => session.pending_count() + 1
          _ => self.config.max_pending_qos1_per_session()
        }
        let stage = match
          session.stage(
            @session.SessionMessage::new(
              candidate.topic,
              candidate.payload,
              candidate.retain,
              qos=candidate.qos,
            ),
            self.session_limits(max_inflight~, max_pending~),
          ) {
          Ok(value) => value
          Err(error) => return Err(SessionFailure(error))
        }
        match stage {
          SendNow(delivery) => {
            inflight_added += 1
            actions.push(
              Deliver({
                recipient: candidate.recipient,
                topic: delivery.message.unwrap().topic,
                payload: copy_router_bytes(delivery.message.unwrap().payload),
                qos: delivery.message.unwrap().qos,
                retain: delivery.message.unwrap().retain,
                packet_id: Some(delivery.packet_id),
                dup: delivery.dup,
              }),
            )
          }
          Queued => pending_added += 1
        }
      }
      DropResource(_) =>
        actions.push(DeliveryDroppedResourceLimit(candidate.recipient))
    }
  }
  prepared_ok = true
  Ok({ actions, updates, inflight_added, pending_added, scratch, usage_updates })
}

///|
fn BrokerState::attach_session(
  self : BrokerState,
  client_id : @session.ClientId,
) -> Result[Array[BrokerAction], RouterError] {
  let session = match self.sessions.get(client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(client_id))
  }
  if session.is_attached() {
    return Err(InvalidSessionState(client_id))
  }
  let before_inflight = session.inflight_count()
  let before_pending = session.pending_count()
  let before_next_packet_id = session.next_packet_id()
  let replay_scratch = match
    self.reserve_scratch(
      session.inflight_bytes() * 4L + session.inflight_count().to_int64() * 128L,
    ) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  defer replay_scratch.release().unwrap()
  let deliveries = match session.attach(self.session_limits(max_inflight=0)) {
    Ok(value) => value
    Err(error) => return Err(SessionFailure(error))
  }
  self.inflight_total = self.inflight_total +
    (session.inflight_count() - before_inflight)
  self.pending_qos1_total = self.pending_qos1_total -
    (before_pending - session.pending_count())
  if session.mode() == @session.SessionMode::Persistent &&
    (
      session.inflight_count() != before_inflight ||
      session.pending_count() != before_pending ||
      session.next_packet_id() != before_next_packet_id
    ) {
    self.mark_snapshot_dirty()
  }
  if self.admin_sessions is Some(index) {
    index.bump(client_id)
  }
  let actions : Array[BrokerAction] = [SessionAttached(client_id)]
  for delivery in deliveries {
    if delivery.message is None {
      actions.push(SendPubrel({ client_id, packet_id: delivery.packet_id }))
      continue
    }
    actions.push(
      Deliver({
        recipient: client_id,
        topic: delivery.message.unwrap().topic,
        payload: copy_router_bytes(delivery.message.unwrap().payload),
        qos: delivery.message.unwrap().qos,
        retain: delivery.message.unwrap().retain,
        packet_id: Some(delivery.packet_id),
        dup: delivery.dup,
      }),
    )
  }
  Ok(actions)
}

///|
fn BrokerState::ack_delivery(
  self : BrokerState,
  client_id : @session.ClientId,
  packet_id : @session.SessionPacketId,
  pubcomp? : Bool = false,
) -> Result[Array[BrokerAction], RouterError] {
  let session = match self.sessions.get(client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(client_id))
  }
  let before_inflight = session.inflight_count()
  let before_pending = session.pending_count()
  let ack = match
    session.ack(packet_id, self.session_limits(max_inflight=0), pubcomp~) {
    Ok(value) => value
    Err(error) => return Err(SessionFailure(error))
  }
  match ack {
    UnknownPacketId => Ok([])
    Acknowledged(promoted) => {
      self.inflight_total = self.inflight_total +
        (session.inflight_count() - before_inflight)
      self.pending_qos1_total = self.pending_qos1_total -
        (before_pending - session.pending_count())
      if session.mode() == @session.SessionMode::Persistent {
        self.mark_snapshot_dirty()
      }
      let actions : Array[BrokerAction] = [
        DeliveryAcknowledged({ client_id, packet_id }),
      ]
      for delivery in promoted {
        actions.push(
          Deliver({
            recipient: client_id,
            topic: delivery.message.unwrap().topic,
            payload: copy_router_bytes(delivery.message.unwrap().payload),
            qos: delivery.message.unwrap().qos,
            retain: delivery.message.unwrap().retain,
            packet_id: Some(delivery.packet_id),
            dup: false,
          }),
        )
      }
      Ok(actions)
    }
  }
}

///|
fn BrokerState::apply_event(
  self : BrokerState,
  event : BrokerEvent,
) -> Result[Array[BrokerAction], RouterError] {
  match event {
    CreateSession(client_id) =>
      self.create_session({
        client_id,
        mode: Clean,
        attached: true,
        owner: @security.Principal::Anonymous,
      })
    CreateSessionWith(request) =>
      self.create_session({
        client_id: request.client_id,
        mode: request.mode,
        attached: request.attached,
        owner: @security.Principal::Anonymous,
      })
    CreateOwnedSessionWith(request) => self.create_session(request)
    RemoveSession(client_id) => self.remove_session(client_id)
    AttachSession(client_id) => self.attach_session(client_id)
    DetachSession(client_id) => {
      let session = match self.sessions.get(client_id) {
        None => return Err(SessionNotFound(client_id))
        Some(value) => value
      }
      if !session.is_attached() {
        return Err(InvalidSessionState(client_id))
      }
      session.detach()
      if self.admin_sessions is Some(index) {
        index.bump(client_id)
      }
      Ok([SessionDetached(client_id)])
    }
    DetachSessionAt(request) => {
      let session = match self.sessions.get(request.client_id) {
        None => return Err(SessionNotFound(request.client_id))
        Some(value) => value
      }
      if !session.is_attached() || request.detached_at_ms < 0L {
        return Err(InvalidSessionState(request.client_id))
      }
      session.detach(detached_at_ms=request.detached_at_ms)
      if self.admin_sessions is Some(index) {
        index.bump(request.client_id)
      }
      if session.mode() == @session.SessionMode::Persistent {
        self.mark_snapshot_dirty()
      }
      Ok([SessionDetached(request.client_id)])
    }
    ExpireSessions(now_ms) => self.expire_sessions(now_ms)
    Subscribe(request) => {
      let client_id = request.client_id
      let entries = request.entries
      if self.sessions.get(client_id) is None {
        return Err(SessionNotFound(client_id))
      }
      if entries.length() == 0 {
        return Err(EmptySubscriptionRequest)
      }
      let results : Array[SubscribeResult] = []
      let successful : Array[@topic.TopicFilter] = []
      let originals : Map[@topic.TopicFilter, @session.DeliveryQoS?] = Map([])
      let persistent = self.session_is_persistent(client_id)
      let mut subscriptions_changed = false
      for entry in entries {
        let existing = self.subscriptions.qos(client_id, entry.filter)
        if originals.get(entry.filter) is None {
          originals.set(entry.filter, existing)
        }
        if existing is None &&
          self.subscriptions.subscription_count_for(client_id) >=
          self.config.max_subscriptions_per_session() {
          results.push(RejectedLimit(SubscriptionsPerSession))
        } else if existing is None &&
          self.subscriptions.subscription_count() >=
          self.config.max_subscriptions_total() {
          results.push(RejectedLimit(SubscriptionsTotal))
        } else {
          if existing is None {
            let usage = self.resources.owners.get(client_id).unwrap().usage
            let next = {
              ..usage,
              subscriptions: usage.subscriptions +
              @budget.subscription_cost(entry.filter.value()),
            }
            if self.resources.set_usages(Map([(client_id, next)])) is Err(_) {
              results.push(RejectedLimit(Bytes))
              continue
            }
          }
          if existing != Some(entry.qos) {
            subscriptions_changed = true
          }
          ignore(self.subscriptions.put(client_id, entry.filter, entry.qos))
          results.push(Granted(entry.qos))
          successful.push(entry.filter)
        }
      }
      let candidates : Array[DeliveryCandidate] = []
      for message in self.retained.matching_for_router(successful) {
        for subscription in self.subscriptions.matches(message.topic) {
          if subscription.client_id == client_id {
            candidates.push({
              recipient: client_id,
              topic: message.topic,
              payload: message.payload,
              qos: @session.min_qos(message.qos, subscription.qos),
              retain: true,
            })
          }
        }
      }
      let preparation = match self.preflight_deliveries(candidates, true) {
        Ok(planned) => self.prepare_deliveries(planned)
        Err(error) => Err(error)
      }
      let prepared = match preparation {
        Ok(value) => value
        Err(error) => {
          for filter, previous in originals {
            match previous {
              Some(qos) =>
                ignore(self.subscriptions.put(client_id, filter, qos))
              None => ignore(self.subscriptions.remove(client_id, filter))
            }
          }
          return Err(error)
        }
      }
      let actions : Array[BrokerAction] = [
        SubscriptionsApplied({ client_id, results }),
      ]
      let delivery_changed = prepared.inflight_added > 0 ||
        prepared.pending_added > 0
      actions.append(self.install_deliveries(prepared))
      if self.admin_sessions is Some(index) {
        for filter, previous in originals {
          if previous is None &&
            self.subscriptions.qos(client_id, filter) is Some(_) {
            index.register_subscription(client_id, filter)
          }
        }
      }
      if persistent && (subscriptions_changed || delivery_changed) {
        self.mark_snapshot_dirty()
      }
      Ok(actions)
    }
    Unsubscribe(request) => {
      let client_id = request.client_id
      let filters = request.filters
      if self.sessions.get(client_id) is None {
        return Err(SessionNotFound(client_id))
      }
      if filters.length() == 0 {
        return Err(EmptyUnsubscriptionRequest)
      }
      let removed : Array[Bool] = []
      for filter in filters {
        let changed = self.subscriptions.remove(client_id, filter)
        removed.push(changed)
        if changed && self.admin_sessions is Some(index) {
          index.remove_subscription(client_id, filter)
        }
      }
      if removed.any(value => value) && self.session_is_persistent(client_id) {
        self.mark_snapshot_dirty()
      }
      Ok([UnsubscriptionsApplied({ client_id, removed })])
    }
    Publish(input) => self.publish_input(input)
    ReceiveQoS2(request) => self.receive_qos2(request)
    Pubrel(request) => self.complete_qos2(request)
    Pubrec(request) => self.receive_pubrec(request)
    Pubcomp(request) =>
      self.ack_delivery(request.client_id, request.packet_id, pubcomp=true)
    Puback(request) => self.ack_delivery(request.client_id, request.packet_id)
  }
}

///|
pub fn BrokerState::check_invariants(
  self : BrokerState,
) -> Result[Unit, RouterError] {
  if !self.subscriptions.check_invariants() {
    return Err(InvariantViolation("subscription index is inconsistent"))
  }
  if self.sessions.length() > self.config.max_sessions() {
    return Err(InvariantViolation("session limit exceeded"))
  }
  if self.subscriptions.subscription_count() < 0 ||
    self.retained.count() < 0 ||
    self.inflight_total < 0 ||
    self.pending_qos1_total < 0 {
    return Err(InvariantViolation("resource count is negative"))
  }
  if self.subscriptions.subscription_count() >
    self.config.max_subscriptions_total() {
    return Err(InvariantViolation("total subscription limit exceeded"))
  }
  if self.retained.count() > self.config.max_retained_messages() {
    return Err(InvariantViolation("retained message limit exceeded"))
  }
  if self.inflight_total > self.config.max_inflight_total() {
    return Err(InvariantViolation("total inflight limit exceeded"))
  }
  if self.pending_qos1_total > self.config.max_pending_qos1_total() {
    return Err(InvariantViolation("total pending qos1 limit exceeded"))
  }
  let mut actual_inflight = 0
  let mut actual_pending = 0
  let mut actual_inbound = 0
  for client_id, session in self.sessions {
    match session.check_invariants(self.session_limits()) {
      Ok(_) => ()
      Err(_) => return Err(InvariantViolation("session is inconsistent"))
    }
    if session.client_id() != client_id {
      return Err(InvariantViolation("session id/key mismatch"))
    }
    actual_inbound += session.inbound_qos2_count()
    actual_inflight = actual_inflight + session.inflight_count()
    actual_pending = actual_pending + session.pending_count()
  }
  if actual_inbound != self.inbound_qos2_total ||
    actual_inbound > self.config.max_inbound_qos2_total() {
    return Err(
      InvariantViolation("inbound QoS 2 count inconsistent or exceeded"),
    )
  }
  if actual_inflight != self.inflight_total ||
    actual_pending != self.pending_qos1_total {
    return Err(InvariantViolation("qos1 total counters are inconsistent"))
  }
  for client_id in self.subscriptions.client_ids() {
    if self.sessions.get(client_id) is None {
      return Err(InvariantViolation("subscription references missing session"))
    }
    if self.subscriptions.subscription_count_for(client_id) >
      self.config.max_subscriptions_per_session() {
      return Err(InvariantViolation("per-session subscription limit exceeded"))
    }
  }
  if self.resources.owners.length() != self.sessions.length() ||
    self.resources.retained_bytes != self.retained.recomputed_cost() {
    return Err(InvariantViolation("resource owner/retained mismatch"))
  }
  for id, owner in self.resources.owners {
    if owner.usage != self.resource_usage(id) {
      return Err(InvariantViolation("session byte ledger mismatch"))
    }
  }
  if (self.policy_slots is Some(_)) != (self.policy_index_ticket is Some(_)) ||
    (self.policy_slots is Some(_)) != (self.policy_incarnations is Some(_)) {
    return Err(InvariantViolation("core policy index ticket mismatch"))
  }
  if self.policy_slots is Some(slots) {
    if slots.live_count() != self.sessions.length() || !slots.check_invariants() {
      return Err(InvariantViolation("core policy session index mismatch"))
    }
    let incarnations = self.policy_incarnations.unwrap()
    if incarnations.length() != self.sessions.length() {
      return Err(InvariantViolation("core policy incarnation count mismatch"))
    }
    for id, _ in self.sessions {
      if slots.get(id.value()) is None || incarnations.get(id) is None {
        return Err(InvariantViolation("core policy session identity missing"))
      }
    }
  }
  Ok(())
}

///|
fn BrokerState::publish_input(
  self : BrokerState,
  input : PublishInput,
) -> Result[Array[BrokerAction], RouterError] {
  if input.retain &&
    input.payload.length() > 0 &&
    self.retained.peek(input.topic) is None &&
    self.retained.count() >= self.config.max_retained_messages() {
    return Err(RetainedLimitReached(self.config.max_retained_messages()))
  }
  let descriptor_bytes = self.subscriptions.subscription_count().to_int64() *
    192L
  let new_retained_cost = if input.retain && input.payload.length() > 0 {
    @budget.message_cost(input.topic.value(), input.payload.length().to_int64()).unwrap()
  } else {
    0L
  }
  if new_retained_cost > 0L &&
    new_retained_cost - 96L >
    self.config.resources.get("max_retained_message_bytes") {
    return Err(ByteResourceLimit(@budget.BudgetError::InvalidAmount))
  }
  let scratch = match
    self.reserve_scratch(descriptor_bytes + new_retained_cost * 2L) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  defer scratch.release().unwrap()
  if input.retain {
    let total = self.resources.retained_bytes -
      self.retained.cost_at(input.topic) +
      new_retained_cost
    match self.resources.set_retained(total) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  let strict = input.origin is Client(_)
  let planned = match
    self.preflight_deliveries(self.delivery_candidates(input, false), strict) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let delivery_changed = self.planned_changes_snapshot(planned)
  let prepared = match self.prepare_deliveries(planned) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut retained_changed = false
  if input.retain {
    let previous = self.retained.peek(input.topic)
    if input.payload.length() == 0 {
      self.retained.remove(input.topic)
      retained_changed = previous is Some(_)
      if retained_changed && self.admin_sessions is Some(index) {
        index.remove_retained(input.topic)
      }
    } else {
      retained_changed = previous !=
        Some({ topic: input.topic, payload: input.payload, qos: input.qos })
      ignore(
        self.retained.put(
          input.topic,
          input.payload,
          input.qos,
          self.config.max_retained_messages(),
        ),
      )
      if previous is None && self.admin_sessions is Some(index) {
        index.register_retained(input.topic)
      }
    }
  }
  let actions = self.install_deliveries(prepared)
  if retained_changed || delivery_changed {
    self.mark_snapshot_dirty()
  }
  Ok(actions)
}

///|
pub fn BrokerState::inbound_qos2_count(self : BrokerState) -> Int {
  self.inbound_qos2_total
}

///|
pub fn BrokerState::has_inbound_qos2(
  self : BrokerState,
  client_id : @session.ClientId,
  packet_id : @session.SessionPacketId,
) -> Bool {
  match self.sessions.get(client_id) {
    Some(session) => session.has_inbound_qos2(packet_id)
    None => false
  }
}

///|
pub fn BrokerState::phase_count(
  self : BrokerState,
  phase : @session.OutboundPhase,
) -> Int {
  let mut total = 0
  for _, session in self.sessions {
    total += session.phase_count(phase)
  }
  total
}

///|
fn BrokerState::receive_qos2(
  self : BrokerState,
  request : InboundQoS2Request,
) -> Result[Array[BrokerAction], RouterError] {
  let session = match self.sessions.get(request.client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(request.client_id))
  }
  if !session.is_attached() {
    return Err(InvalidSessionState(request.client_id))
  }
  if request.publish is Some(input) {
    if input.qos != QoS2 || input.origin != Client(request.client_id) {
      return Err(InvariantViolation("invalid inbound QoS 2 publication"))
    }
  }
  let ack : BrokerAction = SendPubrec({
    client_id: request.client_id,
    packet_id: request.packet_id,
  })
  if session.has_inbound_qos2(request.packet_id) {
    return Ok([ack])
  }
  if session.inbound_qos2_count() >= self.config.max_inbound_qos2_per_session() {
    return Err(InboundQoS2ResourceLimit(InboundQoS2PerSession))
  }
  if self.inbound_qos2_total >= self.config.max_inbound_qos2_total() {
    return Err(InboundQoS2ResourceLimit(InboundQoS2Total))
  }
  let usage = self.resources.owners.get(request.client_id).unwrap().usage
  match
    self.resources.set_usages(
      Map([(request.client_id, { ..usage, inbound: usage.inbound + 64L })]),
    ) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  // All count checks and fallible routing preparation precede mutation. This
  // single-writer event has no await or externally observable intermediate state.
  let deliveries = match request.publish {
    Some(input) =>
      match self.publish_input(input) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    None => []
  }
  // The publisher may also be a routed recipient whose prepared copy was installed.
  let session = self.sessions.get(request.client_id).unwrap()
  ignore(
    session
    .begin_inbound_qos2(request.packet_id, self.session_limits())
    .unwrap(),
  )
  self.inbound_qos2_total += 1
  if session.mode() == @session.SessionMode::Persistent {
    self.mark_snapshot_dirty()
  }
  let actions = [ack]
  actions.append(deliveries)
  Ok(actions)
}

///|
fn BrokerState::complete_qos2(
  self : BrokerState,
  request : PubackRequest,
) -> Result[Array[BrokerAction], RouterError] {
  let session = match self.sessions.get(request.client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(request.client_id))
  }
  if session.complete_inbound_qos2(request.packet_id) {
    self.inbound_qos2_total -= 1
    if session.mode() == @session.SessionMode::Persistent {
      self.mark_snapshot_dirty()
    }
  }
  Ok([
    SendPubcomp({ client_id: request.client_id, packet_id: request.packet_id }),
  ])
}

///|
fn BrokerState::receive_pubrec(
  self : BrokerState,
  request : PubackRequest,
) -> Result[Array[BrokerAction], RouterError] {
  let session = match self.sessions.get(request.client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(request.client_id))
  }
  match session.pubrec(request.packet_id) {
    Err(error) => return Err(SessionFailure(error))
    Ok(changed) =>
      if changed && session.mode() == @session.SessionMode::Persistent {
        self.mark_snapshot_dirty()
      }
  }
  Ok([
    SendPubrel({ client_id: request.client_id, packet_id: request.packet_id }),
  ])
}

///|
priv struct PreparedDeliveries {
  scratch : @budget.Ticket
  actions : Array[BrokerAction]
  updates : Map[@session.ClientId, @session.ClientSession]
  inflight_added : Int
  pending_added : Int
  usage_updates : Map[@session.ClientId, ResourceUsage]
}

///|
/// Installs only fully constructed state. All recoverable failures occur in prepare.
fn BrokerState::install_deliveries(
  self : BrokerState,
  prepared : PreparedDeliveries,
) -> Array[BrokerAction] {
  for client_id, session in prepared.updates {
    self.sessions.set(client_id, session)
  }
  self.inflight_total += prepared.inflight_added
  self.pending_qos1_total += prepared.pending_added
  self.retain_action_lease(prepared.scratch)
  prepared.actions
}

///|
pub fn BrokerState::apply(
  self : BrokerState,
  event : BrokerEvent,
) -> Result[Array[BrokerAction], RouterError] {
  let temporary_bytes = match event {
    Subscribe(request) =>
      self.retained.count().to_int64() * 192L +
      request.entries.length().to_int64() * 192L
    _ => 0L
  }
  let temporary = if temporary_bytes == 0L {
    None
  } else {
    match self.reserve_scratch(temporary_bytes) {
      Ok(t) => Some(t)
      Err(e) => return Err(e)
    }
  }
  let before_bytes = self.managed_bytes() - temporary_bytes
  let before_inflight = self.inflight_count()
  let result = self.apply_event(event)
  if temporary is Some(ticket) {
    ticket.release().unwrap()
  }
  let settlement = if result is Err(_) ||
    event is RemoveSession(_) ||
    event is ExpireSessions(_) ||
    event is Puback(_) ||
    event is Pubrec(_) ||
    event is Pubrel(_) ||
    event is Pubcomp(_) ||
    event is Unsubscribe(_) {
    self.settle_resources()
  } else {
    Ok(())
  }
  match settlement {
    Err(_) =>
      Err(InvariantViolation("resource settlement exceeded prior admission"))
    Ok(_) =>
      match result {
        Err(e) => Err(e)
        Ok(actions) => {
          if self.managed_bytes() < before_bytes ||
            self.inflight_count() < before_inflight ||
            event is AttachSession(_) {
            actions.append(self.resume_pending())
          }
          Ok(actions)
        }
      }
  }
}
