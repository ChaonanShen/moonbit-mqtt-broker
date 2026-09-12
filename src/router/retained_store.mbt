///|
pub struct RetainedStore {
  priv messages : Map[@topic.TopicName, RetainedMessage]
}

///|
pub fn RetainedStore::new() -> RetainedStore {
  { messages: Map([]) }
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
) -> Bool {
  if self.messages.get(topic) is None && self.messages.length() >= max_count {
    return false
  }
  self.messages.set(topic, { topic, payload: copy_bytes(payload), qos })
  true
}

///|
pub fn RetainedStore::remove(
  self : RetainedStore,
  topic : @topic.TopicName,
) -> Unit {
  self.messages.remove(topic)
}

///|
pub fn RetainedStore::get(
  self : RetainedStore,
  topic : @topic.TopicName,
) -> RetainedMessage? {
  match self.messages.get(topic) {
    Some(message) => Some({ ..message, payload: copy_bytes(message.payload) })
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
      result.push({ ..message, payload: copy_bytes(message.payload) })
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
      @budget.message_cost(m.topic.value(), m.payload.length().to_int64()).unwrap()
  }
}

///|
fn RetainedStore::total_cost(self : RetainedStore) -> Int64 {
  let mut total = 0L
  for _, message in self.messages {
    total = @budget.checked_add(
      total,
      @budget.message_cost(
        message.topic.value(),
        message.payload.length().to_int64(),
      ).unwrap(),
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
