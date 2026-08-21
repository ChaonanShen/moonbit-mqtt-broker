///|
pub(all) struct SubscriptionMatch {
  client_id : @session.ClientId
  qos : @session.DeliveryQoS
} derive(Eq, Debug)

///|
pub struct SubscriptionIndex {
  priv by_filter : Map[
    @topic.TopicFilter,
    Map[@session.ClientId, @session.DeliveryQoS],
  ]
  priv by_client : Map[
    @session.ClientId,
    Map[@topic.TopicFilter, @session.DeliveryQoS],
  ]
  priv mut count : Int
}

///|
pub fn SubscriptionIndex::new() -> SubscriptionIndex {
  { by_filter: Map([]), by_client: Map([]), count: 0 }
}

///|
/// Returns true when this inserts a new unique (client, filter) pair.
pub fn SubscriptionIndex::put(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
  qos : @session.DeliveryQoS,
) -> Bool {
  let existed = self.by_client.get(client_id) is Some(filters) &&
    filters.get(filter) is Some(_)
  let filters = match self.by_client.get(client_id) {
    Some(filters) => filters
    None => {
      let next : Map[@topic.TopicFilter, @session.DeliveryQoS] = Map([])
      self.by_client.set(client_id, next)
      next
    }
  }
  let clients = match self.by_filter.get(filter) {
    Some(clients) => clients
    None => {
      let next : Map[@session.ClientId, @session.DeliveryQoS] = Map([])
      self.by_filter.set(filter, next)
      next
    }
  }
  filters.set(filter, qos)
  clients.set(client_id, qos)
  if !existed {
    self.count = self.count + 1
  }
  !existed
}

///|
pub fn SubscriptionIndex::remove(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
) -> Bool {
  match self.by_client.get(client_id) {
    None => false
    Some(filters) =>
      match filters.get(filter) {
        None => false
        Some(_) => {
          filters.remove(filter)
          if filters.length() == 0 {
            self.by_client.remove(client_id)
          }
          let clients = self.by_filter.get(filter).unwrap()
          clients.remove(client_id)
          if clients.length() == 0 {
            self.by_filter.remove(filter)
          }
          self.count = self.count - 1
          true
        }
      }
  }
}

///|
pub fn SubscriptionIndex::remove_all(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
) -> Int {
  let filters = match self.by_client.get(client_id) {
    None => return 0
    Some(filters) => filters.keys().collect()
  }
  let mut removed = 0
  for filter in filters {
    if self.remove(client_id, filter) {
      removed = removed + 1
    }
  }
  removed
}

///|
pub fn SubscriptionIndex::qos(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
) -> @session.DeliveryQoS? {
  match self.by_client.get(client_id) {
    Some(filters) => filters.get(filter)
    None => None
  }
}

///|
pub fn SubscriptionIndex::subscription_count(self : SubscriptionIndex) -> Int {
  self.count
}

///|
pub fn SubscriptionIndex::subscription_count_for(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
) -> Int {
  match self.by_client.get(client_id) {
    Some(filters) => filters.length()
    None => 0
  }
}

///|
/// Finds each client once, combining overlapping matching filters with max QoS.
pub fn SubscriptionIndex::matches(
  self : SubscriptionIndex,
  topic : @topic.TopicName,
) -> Array[SubscriptionMatch] {
  let merged : Map[@session.ClientId, @session.DeliveryQoS] = Map([])
  for entry in self.by_filter {
    let (filter, clients) = entry
    if filter.matches(topic) {
      for entry in clients {
        let (client_id, qos) = entry
        match merged.get(client_id) {
          Some(previous) =>
            merged.set(client_id, @session.max_qos(previous, qos))
          None => merged.set(client_id, qos)
        }
      }
    }
  }
  let result : Array[SubscriptionMatch] = []
  for entry in merged {
    let (client_id, qos) = entry
    result.push({ client_id, qos })
  }
  result.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.client_id.value(), right.client_id.value())
  })
  result
}

///|
pub fn SubscriptionIndex::check_invariants(self : SubscriptionIndex) -> Bool {
  let mut forward_count = 0
  for entry in self.by_filter {
    let (filter, clients) = entry
    if clients.length() == 0 {
      return false
    }
    for entry in clients {
      let (client_id, qos) = entry
      match self.by_client.get(client_id) {
        Some(filters) =>
          match filters.get(filter) {
            Some(reverse_qos) if reverse_qos == qos =>
              forward_count = forward_count + 1
            _ => return false
          }
        None => return false
      }
    }
  }
  forward_count == self.count
}
