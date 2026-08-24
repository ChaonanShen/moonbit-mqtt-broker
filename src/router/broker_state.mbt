///|
pub struct BrokerState {
  config : BrokerConfig
  priv sessions : Map[@session.ClientId, @session.ClientSession]
  priv subscriptions : SubscriptionIndex
  priv retained : RetainedStore
  priv mut inflight_total : Int
  priv mut pending_qos1_total : Int
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
pub fn BrokerState::new(config : BrokerConfig) -> BrokerState {
  {
    config,
    sessions: Map([]),
    subscriptions: SubscriptionIndex::new(),
    retained: RetainedStore::new(),
    inflight_total: 0,
    pending_qos1_total: 0,
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
pub fn BrokerState::session_count(self : BrokerState) -> Int {
  self.sessions.length()
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
  self.sessions.set(
    request.client_id,
    @session.ClientSession::new(
      request.client_id,
      mode=request.mode,
      attached=request.attached,
      owner=request.owner,
    ),
  )
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
  self.inflight_total = self.inflight_total - session.inflight_count()
  self.pending_qos1_total = self.pending_qos1_total - session.pending_count()
  ignore(self.subscriptions.remove_all(client_id))
  self.sessions.remove(client_id)
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
fn BrokerState::delivery_candidates(
  self : BrokerState,
  input : PublishInput,
  retain : Bool,
) -> Array[DeliveryCandidate] {
  let candidates : Array[DeliveryCandidate] = []
  for subscription in self.subscriptions.matches(input.topic) {
    candidates.push({
      recipient: subscription.client_id,
      topic: input.topic,
      payload: copy_router_bytes(input.payload),
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
) -> Result[Array[PlannedDelivery], RouterError] {
  let planned : Array[PlannedDelivery] = []
  let planned_inflight : Map[@session.ClientId, Int] = Map([])
  let planned_pending : Map[@session.ClientId, Int] = Map([])
  let mut inflight_added = 0
  let mut pending_added = 0
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
      QoS1 => {
        let extra_inflight = planned_inflight
          .get(candidate.recipient)
          .unwrap_or(0)
        let extra_pending = planned_pending
          .get(candidate.recipient)
          .unwrap_or(0)
        let session_inflight = session.inflight_count() + extra_inflight
        let session_pending = session.pending_count() + extra_pending
        if session.is_attached() &&
          session_inflight < self.config.max_inflight_per_session() &&
          self.inflight_total + inflight_added <
          self.config.max_inflight_total() {
          planned_inflight.set(candidate.recipient, extra_inflight + 1)
          inflight_added = inflight_added + 1
          planned.push({ candidate, destination: StageInflight })
        } else if session_pending < self.config.max_pending_qos1_per_session() &&
          self.pending_qos1_total + pending_added <
          self.config.max_pending_qos1_total() {
          planned_pending.set(candidate.recipient, extra_pending + 1)
          pending_added = pending_added + 1
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
fn BrokerState::commit_deliveries(
  self : BrokerState,
  planned : Array[PlannedDelivery],
) -> Result[Array[BrokerAction], RouterError] {
  let actions : Array[BrokerAction] = []
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
        let session = self.sessions.get(candidate.recipient).unwrap()
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
            ),
            self.session_limits(max_inflight~, max_pending~),
          ) {
          Ok(value) => value
          Err(error) => return Err(SessionFailure(error))
        }
        match stage {
          SendNow(delivery) => {
            self.inflight_total = self.inflight_total + 1
            actions.push(
              Deliver({
                recipient: candidate.recipient,
                topic: delivery.message.topic,
                payload: copy_router_bytes(delivery.message.payload),
                qos: QoS1,
                retain: delivery.message.retain,
                packet_id: Some(delivery.packet_id),
                dup: delivery.dup,
              }),
            )
          }
          Queued => self.pending_qos1_total = self.pending_qos1_total + 1
        }
      }
      DropResource(_) =>
        actions.push(DeliveryDroppedResourceLimit(candidate.recipient))
    }
  }
  Ok(actions)
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
  let global_free = self.config.max_inflight_total() - self.inflight_total
  let effective_max = if before_inflight + global_free <
    self.config.max_inflight_per_session() {
    before_inflight + global_free
  } else {
    self.config.max_inflight_per_session()
  }
  let deliveries = match
    session.attach(self.session_limits(max_inflight=effective_max)) {
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
  let actions : Array[BrokerAction] = [SessionAttached(client_id)]
  for delivery in deliveries {
    actions.push(
      Deliver({
        recipient: client_id,
        topic: delivery.message.topic,
        payload: copy_router_bytes(delivery.message.payload),
        qos: QoS1,
        retain: delivery.message.retain,
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
) -> Result[Array[BrokerAction], RouterError] {
  let session = match self.sessions.get(client_id) {
    Some(value) => value
    None => return Err(SessionNotFound(client_id))
  }
  let before_inflight = session.inflight_count()
  let before_pending = session.pending_count()
  let global_free = self.config.max_inflight_total() - self.inflight_total
  let effective_max = if before_inflight + global_free <
    self.config.max_inflight_per_session() {
    before_inflight + global_free
  } else {
    self.config.max_inflight_per_session()
  }
  let ack = match
    session.ack(packet_id, self.session_limits(max_inflight=effective_max)) {
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
            topic: delivery.message.topic,
            payload: copy_router_bytes(delivery.message.payload),
            qos: QoS1,
            retain: delivery.message.retain,
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
pub fn BrokerState::apply(
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
          if existing != Some(entry.qos) {
            subscriptions_changed = true
          }
          ignore(self.subscriptions.put(client_id, entry.filter, entry.qos))
          results.push(Granted(entry.qos))
          successful.push(entry.filter)
        }
      }
      let candidates : Array[DeliveryCandidate] = []
      for message in self.retained.matching(successful) {
        for subscription in self.subscriptions.matches(message.topic) {
          if subscription.client_id == client_id {
            candidates.push({
              recipient: client_id,
              topic: message.topic,
              payload: copy_router_bytes(message.payload),
              qos: @session.min_qos(message.qos, subscription.qos),
              retain: true,
            })
          }
        }
      }
      let planned = match self.preflight_deliveries(candidates, true) {
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
      let delivery_changed = self.planned_changes_snapshot(planned)
      match self.commit_deliveries(planned) {
        Ok(deliveries) => actions.append(deliveries)
        Err(error) => return Err(error)
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
        removed.push(self.subscriptions.remove(client_id, filter))
      }
      if removed.any(value => value) && self.session_is_persistent(client_id) {
        self.mark_snapshot_dirty()
      }
      Ok([UnsubscriptionsApplied({ client_id, removed })])
    }
    Publish(input) => {
      if input.retain &&
        input.payload.length() > 0 &&
        self.retained.get(input.topic) is None &&
        self.retained.count() >= self.config.max_retained_messages() {
        return Err(RetainedLimitReached(self.config.max_retained_messages()))
      }
      let strict = input.origin is Client(_)
      let planned = match
        self.preflight_deliveries(
          self.delivery_candidates(input, false),
          strict,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let delivery_changed = self.planned_changes_snapshot(planned)
      let mut retained_changed = false
      if input.retain {
        let previous = self.retained.get(input.topic)
        if input.payload.length() == 0 {
          self.retained.remove(input.topic)
          retained_changed = previous is Some(_)
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
        }
      }
      let actions = self.commit_deliveries(planned)
      if actions is Ok(_) && (retained_changed || delivery_changed) {
        self.mark_snapshot_dirty()
      }
      actions
    }
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
  for client_id, session in self.sessions {
    match session.check_invariants(self.session_limits()) {
      Ok(_) => ()
      Err(_) => return Err(InvariantViolation("session is inconsistent"))
    }
    if session.client_id() != client_id {
      return Err(InvariantViolation("session id/key mismatch"))
    }
    actual_inflight = actual_inflight + session.inflight_count()
    actual_pending = actual_pending + session.pending_count()
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
  Ok(())
}
