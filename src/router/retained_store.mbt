///|
pub struct RetainedStore {
  priv mut bytes : Int64
  priv messages : Map[@topic.TopicName, RetainedMessage]
  priv revisions : Map[@topic.TopicName, Int64]
  priv mut next_revision : Int64
}

///|
pub fn RetainedStore::new() -> RetainedStore {
  { bytes: 0L, messages: Map([]), revisions: Map([]), next_revision: 1L }
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
  if self.messages.get(topic) is None && self.messages.length() >= max_count {
    return false
  }
  if self.next_revision == 9223372036854775807L {
    return false
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
    if matched {
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
    if filters.any(filter => filter.matches(message.topic)) {
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
