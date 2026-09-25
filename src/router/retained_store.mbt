///|
pub struct RetainedStore {
  priv mut bytes : Int64
  priv messages : Map[@topic.TopicName, RetainedMessage]
  priv revisions : Map[@topic.TopicName, Int64]
  priv mut next_revision : Int64
  priv expiry : @session.ExpiryScheduler
}

///|
pub fn RetainedStore::new() -> RetainedStore {
  {
    bytes: 0L,
    messages: Map([]),
    revisions: Map([]),
    next_revision: 1L,
    expiry: @session.ExpiryScheduler::new(65535, 8388608L),
  }
}

///|
fn copy_bytes(payload : Bytes) -> Bytes {
  Bytes::from_array(payload.to_array())
}

///|
/// Stores a copy. Returns false only when a new topic would exceed max_count.
pub fn RetainedStore::put(
  self : RetainedStore,
  topic : @topic.TopicName,
  payload : Bytes,
  qos : @session.DeliveryQoS,
  max_count : Int,
  metadata? : @session.MessageMetadata = @session.MessageMetadata::empty(),
) -> Bool {
  if !self.can_put(topic, max_count, metadata) {
    return false
  }
  if metadata.expiry is Some(deadline) {
    if !self.expiry.set(topic.value(), deadline.mono_due_ms, self.next_revision) {
      return false
    }
  } else {
    ignore(self.expiry.remove(topic.value()))
  }
  self.bytes = self.bytes -
    self.cost_at(topic) +
    @budget.message_cost(topic.value(), payload.length().to_int64()).unwrap() +
    metadata.cost()
  self.revisions.set(topic, self.next_revision)
  self.next_revision += 1L
  self.messages.set(topic, {
    topic,
    payload: copy_bytes(payload),
    qos,
    metadata: metadata.copy(),
  })
  true
}

///|
pub fn RetainedStore::remove(
  self : RetainedStore,
  topic : @topic.TopicName,
) -> Unit {
  self.bytes -= self.cost_at(topic)
  self.messages.remove(topic)
  self.revisions.remove(topic)
  ignore(self.expiry.remove(topic.value()))
}

///|
pub fn RetainedStore::get(
  self : RetainedStore,
  topic : @topic.TopicName,
) -> RetainedMessage? {
  match self.messages.get(topic) {
    Some(message) =>
      Some({
        ..message,
        payload: copy_bytes(message.payload),
        metadata: message.metadata.copy(),
      })
    None => None
  }
}

///|
pub fn RetainedStore::count(self : RetainedStore) -> Int {
  self.messages.length()
}

///|
pub fn RetainedStore::matching(
  self : RetainedStore,
  filters : Array[@topic.TopicFilter],
) -> Array[RetainedMessage] {
  let result : Array[RetainedMessage] = []
  for entry in self.messages {
    let (_, message) = entry
    let mut matched = false
    for filter in filters {
      if filter.matches(message.topic) {
        matched = true
      }
    }
    if matched &&
      !(message.metadata.expiry is Some(deadline) &&
      deadline.remaining_at(@budget.monotonic_ms()) == 0L) {
      result.push({
        ..message,
        payload: copy_bytes(message.payload),
        metadata: message.metadata.copy(),
      })
    }
  }
  result.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.topic.value(), right.topic.value())
  })
  result
}

///|
fn RetainedStore::all_messages(self : RetainedStore) -> Array[RetainedMessage] {
  let result : Array[RetainedMessage] = []
  for _, message in self.messages {
    result.push({
      topic: message.topic,
      payload: copy_bytes(message.payload),
      qos: message.qos,
      metadata: message.metadata.copy(),
    })
  }
  result.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.topic.value(), right.topic.value())
  })
  result
}

///|
/// Internal immutable borrow; avoids payload copies during preflight.
fn RetainedStore::peek(
  self : RetainedStore,
  topic : @topic.TopicName,
) -> RetainedMessage? {
  self.messages.get(topic)
}

///|
fn RetainedStore::cost_at(
  self : RetainedStore,
  topic : @topic.TopicName,
) -> Int64 {
  match self.messages.get(topic) {
    None => 0L
    Some(m) =>
      @budget.message_cost(m.topic.value(), m.payload.length().to_int64()).unwrap() +
      m.metadata.cost()
  }
}

///|
fn RetainedStore::total_cost(self : RetainedStore) -> Int64 {
  self.bytes
}

///|
fn RetainedStore::recomputed_cost(self : RetainedStore) -> Int64 {
  let mut total = 0L
  for _, message in self.messages {
    total = @budget.checked_add(
      total,
      @budget.message_cost(
        message.topic.value(),
        message.payload.length().to_int64(),
      ).unwrap() +
      message.metadata.cost(),
    ).unwrap()
  }
  total
}

///|
fn RetainedStore::matching_for_router(
  self : RetainedStore,
  filters : Array[@topic.TopicFilter],
) -> Array[RetainedMessage] {
  let result : Array[RetainedMessage] = []
  for _, message in self.messages {
    if filters.any(filter => filter.matches(message.topic)) &&
      !(message.metadata.expiry is Some(deadline) &&
      deadline.remaining_at(@budget.monotonic_ms()) == 0L) {
      result.push(message)
    }
  }
  result.sort_by((left, right) => {
    compare_utf8_for_sort(left.topic.value(), right.topic.value())
  })
  result
}

///|
/// Only topic identities are returned; retained payloads are not copied.
fn RetainedStore::topic_keys(self : RetainedStore) -> Array[@topic.TopicName] {
  self.messages.keys().collect()
}

///|
pub fn BrokerState::has_retained(
  self : BrokerState,
  topic : @topic.TopicName,
) -> Bool {
  self.retained.peek(topic) is Some(_)
}

///|
pub fn RetainedStore::revision(
  self : RetainedStore,
  topic : @topic.TopicName,
) -> Int64? {
  self.revisions.get(topic)
}

///|
pub fn RetainedStore::next_revision(self : RetainedStore) -> Int64 {
  self.next_revision
}

///|
fn RetainedStore::restore_revision(
  self : RetainedStore,
  topic : @topic.TopicName,
  revision : Int64,
) -> Bool {
  if revision < 1L || self.messages.get(topic) is None {
    return false
  }
  self.revisions.set(topic, revision)
  if self.messages.get(topic) is Some(message) &&
    message.metadata.expiry is Some(deadline) &&
    !self.expiry.set(topic.value(), deadline.mono_due_ms, revision) {
    return false
  }
  if revision >= self.next_revision {
    self.next_revision = revision + 1L
  }
  true
}

///|
fn RetainedStore::ensure_next_revision(
  self : RetainedStore,
  floor : Int64,
) -> Bool {
  if floor < 1L {
    return false
  }
  for _, revision in self.revisions {
    if revision >= floor {
      return false
    }
  }
  self.next_revision = floor
  true
}

///|
fn RetainedStore::next_expired(
  self : RetainedStore,
  now_mono_ms : Int64,
) -> @topic.TopicName? {
  let entry = match self.expiry.peek_due(now_mono_ms) {
    Some(value) => value
    None => return None
  }
  let topic = @topic.TopicName::new(entry.key).unwrap()
  if self.revisions.get(topic) == Some(entry.revision) {
    Some(topic)
  } else {
    None
  }
}

///|
fn RetainedStore::expiry_index_bytes(self : RetainedStore) -> Int64 {
  self.expiry.used_bytes()
}

///|
fn RetainedStore::expiry_put_delta(
  self : RetainedStore,
  topic : @topic.TopicName,
  metadata : @session.MessageMetadata,
) -> Int64 {
  if metadata.expiry is Some(_) {
    self.expiry.projected_set_delta(topic.value())
  } else {
    -self.expiry.get(topic.value()).map(entry => entry.cost_bytes).unwrap_or(0L)
  }
}

///|
fn RetainedStore::can_put(
  self : RetainedStore,
  topic : @topic.TopicName,
  max_count : Int,
  metadata : @session.MessageMetadata,
) -> Bool {
  (self.messages.get(topic) is Some(_) || self.messages.length() < max_count) &&
  self.next_revision < 9223372036854775807L &&
  (metadata.expiry is None || self.expiry.can_set(topic.value()))
}

///|
fn RetainedStore::expiry_index_valid(self : RetainedStore) -> Bool {
  if !self.expiry.check_invariants() {
    return false
  }
  let mut expected = 0
  for topic, message in self.messages {
    if message.metadata.expiry is Some(deadline) {
      expected += 1
      let entry = match self.expiry.get(topic.value()) {
        Some(value) => value
        None => return false
      }
      if entry.due_mono_ms != deadline.mono_due_ms ||
        self.revisions.get(topic) != Some(entry.revision) {
        return false
      }
    }
  }
  self.expiry.length() == expected
}
