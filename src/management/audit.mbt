///|
pub(all) struct AuditEvent {
  sequence : Int64
  timestamp_ms : Int64
  actor_token_id : String
  operation_id : String
  kind : OperationKind
  target : String
  phase : String
  result : String
  effect_applied : Bool
  state_revision : Int64?
} derive(Eq, Debug)

///|
pub(all) struct AuditPage {
  items : Array[AuditEvent]
  next_after_sequence : Int64?
  oldest_available_sequence : Int64
  overwritten_total : Int64
  gap : Bool
  scanned : Int
} derive(Eq, Debug)

///|
/// In-memory overwrite ring. It never writes to synchronous Logger.log and
/// cannot block an accepted command when historical audit entries are lost.
pub struct AuditRing {
  slots : Array[AuditEvent?]
  mut head : Int
  mut count : Int
  mut next_sequence : Int64
  mut overwritten_total : Int64
}

///|
pub fn AuditRing::new(capacity : Int) -> AuditRing {
  {
    slots: Array::make(capacity, None),
    head: 0,
    count: 0,
    next_sequence: 1L,
    overwritten_total: 0L,
  }
}

///|
pub fn AuditRing::count(self : AuditRing) -> Int {
  self.count
}

///|
pub fn AuditRing::overwritten_total(self : AuditRing) -> Int64 {
  self.overwritten_total
}

///|
pub fn AuditRing::oldest_available_sequence(self : AuditRing) -> Int64 {
  if self.count == 0 {
    self.next_sequence
  } else {
    self.next_sequence - self.count.to_int64()
  }
}

///|
pub fn AuditRing::append(self : AuditRing, event : AuditEvent) -> Bool {
  let capacity = self.slots.length()
  if capacity == 0 ||
    self.next_sequence <= 0L ||
    self.next_sequence == 9223372036854775807L {
    return false
  }
  let index = if self.count == capacity {
    let old = self.head
    self.head = (self.head + 1) % capacity
    self.overwritten_total += 1L
    old
  } else {
    let next = (self.head + self.count) % capacity
    self.count += 1
    next
  }
  self.slots[index] = Some({ ..event, sequence: self.next_sequence })
  self.next_sequence += 1L
  true
}

///|
/// Reads at most scan_limit sequence positions. Actor filtering may yield an
/// empty page with a forward cursor; reading never writes another event.
pub fn AuditRing::page(
  self : AuditRing,
  actor_token_id : String,
  after_sequence : Int64,
  limit : Int,
  scan_limit : Int,
) -> AuditPage {
  let items : Array[AuditEvent] = []
  let oldest = self.oldest_available_sequence()
  let gap = after_sequence > 0L && after_sequence < oldest - 1L
  let first = if after_sequence < oldest - 1L {
    oldest
  } else {
    after_sequence + 1L
  }
  let mut sequence = first
  let mut scanned = 0
  while sequence < self.next_sequence &&
        scanned < scan_limit &&
        items.length() < limit {
    let offset = (sequence - oldest).to_int()
    let index = (self.head + offset) % self.slots.length()
    if self.slots[index] is Some(event) &&
      event.actor_token_id == actor_token_id {
      items.push(event)
    }
    sequence += 1L
    scanned += 1
  }
  {
    items,
    next_after_sequence: if sequence < self.next_sequence {
      Some(sequence - 1L)
    } else {
      None
    },
    oldest_available_sequence: oldest,
    overwritten_total: self.overwritten_total,
    gap,
    scanned,
  }
}

///|
pub fn AuditEvent::to_json(self : AuditEvent) -> Json {
  let fields : Map[String, Json] = Map([
    ("sequence", self.sequence.to_string().to_json()),
    ("timestamp_ms", self.timestamp_ms.to_string().to_json()),
    ("operation_id", self.operation_id.to_json()),
    ("kind", operation_kind_name(self.kind).to_json()),
    ("target", self.target.to_json()),
    ("phase", self.phase.to_json()),
    ("result", self.result.to_json()),
    ("effect_applied", self.effect_applied.to_json()),
    ("state_revision", optional_decimal_json(self.state_revision)),
  ])
  fields.to_json()
}
