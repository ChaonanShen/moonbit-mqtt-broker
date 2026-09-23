///|
pub(all) enum OperationKind {
  Kick
  DeleteSession
  Reload
} derive(Eq, Debug)

///|
pub(all) enum OperationState {
  Accepted
  Running
  Succeeded
  Failed
} derive(Eq, Debug)

///|
pub(all) enum OperationStage {
  Queued
  ClosingTransport
  WaitingAuthReap
  Applying
  Done
} derive(Eq, Debug)

///|
pub(all) enum OperationError {
  IdempotencyConflict
  OperationCapacity
  OperationIdExhausted
  OperationNotFound
} derive(Eq, Debug)

///|
pub(all) struct OperationRecord {
  id : String
  actor_token_id : String
  kind : OperationKind
  target : String
  normalized_request : String
  idempotency_key : String
  accepted_at_ms : Int64
  started_at_ms : Int64?
  finished_at_ms : Int64?
  state : OperationState
  stage : OperationStage
  effect_applied : Bool
  transport_closed : Bool
  timed_out : Bool
  completion_scope : String
  persistence_mode : String
  state_revision_after : Int64?
  snapshot_committed_revision_at_finish : Int64?
  error_code : String?
  deadline_monotonic_ms : Int64
  terminal_expiry_ms : Int64?
} derive(Eq, Debug)

///|
pub(all) enum IdempotencyLookup {
  KeyUnused
  KeyMatch(OperationRecord)
  KeyConflict
} derive(Eq, Debug)

///|
pub struct OperationTable {
  boot_id : String
  slots : Array[OperationRecord?]
  by_id : Map[String, Int]
  by_actor : Map[String, Map[String, String]]
  mut next_sequence : Int64
  mut next_free_scan : Int
  mut cleanup_slot : Int
  retention_ms : Int64
}

///|
pub fn OperationTable::new(
  boot_id : String,
  capacity : Int,
  retention_ms : Int64,
) -> OperationTable {
  {
    boot_id,
    slots: Array::make(capacity, None),
    by_id: Map([]),
    by_actor: Map([]),
    next_sequence: 1L,
    next_free_scan: 0,
    cleanup_slot: 0,
    retention_ms,
  }
}

///|
pub fn OperationTable::live_count(self : OperationTable) -> Int {
  self.by_id.length()
}

///|
pub fn OperationTable::lookup_key(
  self : OperationTable,
  actor : String,
  idempotency_key : String,
  normalized_request : String,
) -> IdempotencyLookup {
  match self.by_actor.get(actor) {
    None => KeyUnused
    Some(keys) =>
      match keys.get(idempotency_key) {
        None => KeyUnused
        Some(id) =>
          match self.by_id.get(id) {
            None => KeyConflict
            Some(slot) =>
              match self.slots[slot] {
                Some(record) =>
                  if record.normalized_request == normalized_request {
                    KeyMatch(record)
                  } else {
                    KeyConflict
                  }
                None => KeyConflict
              }
          }
      }
  }
}

///|
pub fn OperationTable::get(
  self : OperationTable,
  id : String,
  actor : String,
) -> OperationRecord? {
  match self.by_id.get(id) {
    None => None
    Some(slot) =>
      match self.slots[slot] {
        Some(record) if record.actor_token_id == actor => Some(record)
        _ => None
      }
  }
}

///|
pub fn OperationTable::get_internal(
  self : OperationTable,
  id : String,
) -> OperationRecord? {
  match self.by_id.get(id) {
    Some(slot) => self.slots[slot]
    None => None
  }
}

///|
/// Caller prechecks target/etag and all other admission slots first. This
/// function performs the table/idempotency insertion synchronously.
pub fn OperationTable::insert(
  self : OperationTable,
  actor : String,
  kind : OperationKind,
  target : String,
  normalized_request : String,
  idempotency_key : String,
  persistence_mode : String,
  accepted_at_ms : Int64,
  deadline_monotonic_ms : Int64,
) -> Result[OperationRecord, OperationError] {
  if self.lookup_key(actor, idempotency_key, normalized_request) != KeyUnused {
    return Err(IdempotencyConflict)
  }
  if self.next_sequence <= 0L || self.next_sequence == 9223372036854775807L {
    return Err(OperationIdExhausted)
  }
  if self.by_id.length() == self.slots.length() {
    return Err(OperationCapacity)
  }
  let capacity = self.slots.length()
  let mut slot = -1
  for offset in 0..<capacity {
    let candidate = (self.next_free_scan + offset) % capacity
    if self.slots[candidate] is None {
      slot = candidate
      break
    }
  }
  if slot < 0 {
    return Err(OperationCapacity)
  }
  let id = self.boot_id + "." + self.next_sequence.to_string()
  self.next_sequence += 1L
  let record : OperationRecord = {
    id,
    actor_token_id: actor,
    kind,
    target,
    normalized_request,
    idempotency_key,
    accepted_at_ms,
    started_at_ms: None,
    finished_at_ms: None,
    state: Accepted,
    stage: Queued,
    effect_applied: false,
    transport_closed: false,
    timed_out: false,
    completion_scope: "runtime",
    persistence_mode,
    state_revision_after: None,
    snapshot_committed_revision_at_finish: None,
    error_code: None,
    deadline_monotonic_ms,
    terminal_expiry_ms: None,
  }
  let keys = match self.by_actor.get(actor) {
    Some(value) => value
    None => {
      let created : Map[String, String] = Map([])
      self.by_actor.set(actor, created)
      created
    }
  }
  keys.set(idempotency_key, id)
  self.by_id.set(id, slot)
  self.slots[slot] = Some(record)
  self.next_free_scan = (slot + 1) % capacity
  Ok(record)
}

///|
pub fn OperationTable::replace(
  self : OperationTable,
  record : OperationRecord,
) -> Bool {
  match self.by_id.get(record.id) {
    None => false
    Some(slot) =>
      match self.slots[slot] {
        Some(existing) if existing.actor_token_id == record.actor_token_id &&
          existing.idempotency_key == record.idempotency_key => {
          self.slots[slot] = Some(record)
          true
        }
        _ => false
      }
  }
}

///|
pub fn OperationTable::start(
  self : OperationTable,
  id : String,
  stage : OperationStage,
  now_ms : Int64,
) -> Bool {
  match self.get_internal(id) {
    Some(record) if record.state == Accepted =>
      self.replace({
        ..record,
        state: Running,
        stage,
        started_at_ms: Some(now_ms),
      })
    _ => false
  }
}

///|
pub fn OperationTable::finish(
  self : OperationTable,
  id : String,
  succeeded : Bool,
  effect_applied : Bool,
  transport_closed : Bool,
  timed_out : Bool,
  error_code : String?,
  state_revision_after : Int64?,
  snapshot_committed_revision_at_finish : Int64?,
  now_ms : Int64,
  monotonic_ms : Int64,
) -> Bool {
  match self.get_internal(id) {
    Some(record) if record.state == Accepted || record.state == Running =>
      self.replace({
        ..record,
        state: if succeeded {
          Succeeded
        } else {
          Failed
        },
        stage: Done,
        effect_applied,
        transport_closed,
        timed_out,
        error_code,
        state_revision_after,
        snapshot_committed_revision_at_finish,
        finished_at_ms: Some(now_ms),
        terminal_expiry_ms: Some(monotonic_ms + self.retention_ms),
      })
    _ => false
  }
}

///|
/// A running record is never subject to the terminal TTL.
pub fn OperationTable::cleanup(
  self : OperationTable,
  now_monotonic_ms : Int64,
  scan_limit : Int,
) -> Int {
  let capacity = self.slots.length()
  if capacity == 0 || scan_limit <= 0 {
    return 0
  }
  let mut removed = 0
  let mut inspected = 0
  while inspected < scan_limit && inspected < capacity {
    let slot = self.cleanup_slot
    self.cleanup_slot = (slot + 1) % capacity
    if self.slots[slot] is Some(record) &&
      record.terminal_expiry_ms is Some(expiry) &&
      now_monotonic_ms >= expiry {
      self.slots[slot] = None
      self.by_id.remove(record.id)
      if self.by_actor.get(record.actor_token_id) is Some(keys) {
        keys.remove(record.idempotency_key)
        if keys.length() == 0 {
          self.by_actor.remove(record.actor_token_id)
        }
      }
      removed += 1
    }
    inspected += 1
  }
  removed
}

///|
pub fn OperationTable::check_invariants(self : OperationTable) -> Bool {
  let mut live = 0
  for slot in self.slots {
    if slot is Some(record) {
      live += 1
      if self.by_actor.get(record.actor_token_id) is Some(keys) {
        if keys.get(record.idempotency_key) != Some(record.id) {
          return false
        }
      } else {
        return false
      }
    }
  }
  live == self.by_id.length()
}
