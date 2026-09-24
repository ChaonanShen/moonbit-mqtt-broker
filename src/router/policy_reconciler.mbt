///|
pub(all) enum PolicyIssue {
  EvictSession(@session.ClientId, Int64)
  DropFilter(@session.ClientId, Int64, Int64, @topic.TopicFilter)
  DropPending(@session.ClientId, Int64, Int64, Int, String, Int, Int)
} derive(Eq, Debug)

///|
pub(all) enum PolicyScanResult {
  PolicyScanIssue(PolicyIssue)
  PolicyScanProgress
  PolicyScanWaiting
  PolicyScanDone
  PolicyScanUnavailable
} derive(Eq, Debug)

///|
/// The session and subscription slot indexes are core-owned and survive when
/// management details are off. A call inspects at most max_items descriptors.
pub struct PolicyReconciler {
  policy : @security.SecurityPolicy
  policy_epoch : Int64
  max_items : Int
  max_bytes : Int64
  mut phase : Int
  mut slot : Int
  mut item : Int
  mut current_id : @session.ClientId?
  mut current_incarnation : Int64
  mut observed_revision : Int64
  mut pending_frontier : Int
  mut waiting : PolicyIssue?
}

///|
pub fn PolicyReconciler::new(
  policy : @security.SecurityPolicy,
  policy_epoch : Int64,
  max_items : Int,
  max_bytes : Int64,
) -> PolicyReconciler? {
  if policy_epoch < 1L ||
    max_items < 1 ||
    max_items > 256 ||
    max_bytes < 65536L ||
    max_bytes > 4194304L {
    return None
  }
  Some({
    policy,
    policy_epoch,
    max_items,
    max_bytes,
    phase: 0,
    slot: 0,
    item: 0,
    current_id: None,
    current_incarnation: 0L,
    observed_revision: 0L,
    pending_frontier: 0,
    waiting: None,
  })
}

///|
pub fn PolicyReconciler::complete_issue(
  self : PolicyReconciler,
  issue : PolicyIssue,
) -> Bool {
  if self.waiting != Some(issue) {
    return false
  }
  self.waiting = None
  true
}

///|
pub fn PolicyReconciler::policy_epoch(self : PolicyReconciler) -> Int64 {
  self.policy_epoch
}

///|
fn PolicyReconciler::next_phase(self : PolicyReconciler) -> Unit {
  self.phase += 1
  self.slot = 0
  self.item = 0
  self.current_id = None
  self.current_incarnation = 0L
  self.observed_revision = 0L
  self.pending_frontier = 0
}

///|
fn PolicyReconciler::inspect_session(
  self : PolicyReconciler,
  state : BrokerState,
  pending : Bool,
) -> PolicyScanResult {
  let page = match state.policy_session_page(self.slot, 1) {
    Some(value) => value
    None => return PolicyScanUnavailable
  }
  if page.scanned == 0 {
    self.next_phase()
    return PolicyScanProgress
  }
  if page.keys.is_empty() {
    self.slot = page.next_slot
    self.current_id = None
    return PolicyScanProgress
  }
  let id = @session.ClientId::new(page.keys[0]).unwrap()
  let incarnation = match state.policy_session_incarnation(id) {
    Some(value) => value
    None => {
      self.slot = page.next_slot
      self.current_id = None
      return PolicyScanProgress
    }
  }
  let session = match state.sessions.get(id) {
    Some(value) => value
    None => {
      self.slot = page.next_slot
      self.current_id = None
      return PolicyScanProgress
    }
  }
  if self.current_id != Some(id) || self.current_incarnation != incarnation {
    self.current_id = Some(id)
    self.current_incarnation = incarnation
    self.observed_revision = session.policy_revision()
    self.item = 0
    self.pending_frontier = session.pending_count()
  } else if self.observed_revision != session.policy_revision() {
    self.observed_revision = session.policy_revision()
    self.item = 0
    if session.pending_count() < self.pending_frontier {
      self.pending_frontier = session.pending_count()
    }
  }
  let principal = session.owner()
  if !self.policy.allows_principal(principal) {
    let issue = EvictSession(id, incarnation)
    self.waiting = Some(issue)
    return PolicyScanIssue(issue)
  }
  if !pending {
    let inflight = session.inflight_item_reference(self.item)
    match inflight {
      None => {
        self.slot = page.next_slot
        self.current_id = None
        self.item = 0
        PolicyScanProgress
      }
      Some(value) =>
        if value.message is Some(message) &&
          !self.policy.can_read_topic(principal, message.topic) {
          let issue = EvictSession(id, incarnation)
          self.waiting = Some(issue)
          PolicyScanIssue(issue)
        } else {
          self.item += 1
          PolicyScanProgress
        }
    }
  } else if self.item >= self.pending_frontier {
    self.slot = page.next_slot
    self.current_id = None
    self.item = 0
    PolicyScanProgress
  } else {
    let message = match session.pending_item_reference(self.item) {
      Some(value) => value
      None => {
        self.pending_frontier = self.item
        return PolicyScanProgress
      }
    }
    if !self.policy.can_read_topic(principal, message.topic) {
      let issue = DropPending(
        id,
        incarnation,
        session.policy_revision(),
        self.item,
        message.topic.value(),
        snapshot_qos(message.qos),
        message.payload.length(),
      )
      self.waiting = Some(issue)
      PolicyScanIssue(issue)
    } else {
      self.item += 1
      PolicyScanProgress
    }
  }
}

///|
fn PolicyReconciler::inspect_subscription(
  self : PolicyReconciler,
  state : BrokerState,
) -> PolicyScanResult {
  let page = match state.policy_subscription_page(self.slot, 1) {
    Some(value) => value
    None => return PolicyScanUnavailable
  }
  if page.scanned == 0 {
    self.next_phase()
    return PolicyScanProgress
  }
  if page.rows.is_empty() {
    self.slot = page.next_slot
    return PolicyScanProgress
  }
  let row = page.rows[0]
  let incarnation = match state.policy_session_incarnation(row.client_id) {
    Some(value) => value
    None => {
      self.slot = page.next_slot
      return PolicyScanProgress
    }
  }
  let principal = match state.session_owner(row.client_id) {
    Some(value) => value
    None => {
      self.slot = page.next_slot
      return PolicyScanProgress
    }
  }
  if !self.policy.allows_principal(principal) ||
    !self.policy.can_read_filter(principal, row.filter) {
    let issue = DropFilter(row.client_id, incarnation, row.id, row.filter)
    self.waiting = Some(issue)
    PolicyScanIssue(issue)
  } else {
    self.slot = page.next_slot
    PolicyScanProgress
  }
}

///|
/// Return one issue or bounded progress. The owner must commit or discard an
/// issue and acknowledge it before scanning again.
pub fn PolicyReconciler::next(
  self : PolicyReconciler,
  state : BrokerState,
) -> PolicyScanResult {
  if self.waiting is Some(_) {
    return PolicyScanWaiting
  }
  let mut inspected = 0
  let mut bytes = 0L
  while inspected < self.max_items && bytes < self.max_bytes {
    if self.phase >= 3 {
      return PolicyScanDone
    }
    let result = match self.phase {
      0 => self.inspect_session(state, false)
      1 => self.inspect_subscription(state)
      _ => self.inspect_session(state, true)
    }
    match result {
      PolicyScanIssue(issue) => return PolicyScanIssue(issue)
      PolicyScanUnavailable => return PolicyScanUnavailable
      PolicyScanDone | PolicyScanWaiting => return result
      PolicyScanProgress => {
        inspected += 1
        bytes += 131328L
      }
    }
  }
  PolicyScanProgress
}
