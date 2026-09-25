///|
pub(all) struct SubscriptionMatch {
  client_id : @session.ClientId
  qos : @session.DeliveryQoS
} derive(Eq, Debug)

///|
pub(all) struct SubscriptionRecord {
  filter : @topic.TopicFilter
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
  priv bindings : Map[
    @session.ClientId,
    Map[@topic.TopicFilter, SubscriptionBinding],
  ]
  priv mut next_identity : Int64
  priv mut count : Int
  priv mut policy_slots : PolicySubscriptionSlots?
}

///|
pub fn SubscriptionIndex::new() -> SubscriptionIndex {
  {
    by_filter: Map([]),
    by_client: Map([]),
    bindings: Map([]),
    next_identity: 1L,
    count: 0,
    policy_slots: None,
  }
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
  if self.next_identity == 9223372036854775807L {
    abort("subscription identity exhausted")
  }
  let bindings = match self.bindings.get(client_id) {
    Some(value) => value
    None => {
      let value : Map[@topic.TopicFilter, SubscriptionBinding] = Map([])
      self.bindings.set(client_id, value)
      value
    }
  }
  bindings.set(filter, {
    identity: self.next_identity,
    filter,
    qos,
    no_local: false,
    retain_as_published: false,
    retain_handling: 0,
    subscription_identifier: None,
  })
  self.next_identity += 1L
  if !existed {
    if self.policy_slots is Some(slots) && !slots.track(client_id, filter) {
      abort("core policy subscription slot exhausted")
    }
    self.count = self.count + 1
  }
  !existed
}

///|
pub fn SubscriptionIndex::put_v5(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
  qos : @session.DeliveryQoS,
  no_local : Bool,
  retain_as_published : Bool,
  retain_handling : Int,
  subscription_identifier : Int?,
) -> Bool {
  let added = self.put(client_id, filter, qos)
  let prior = self.bindings.get(client_id).unwrap().get(filter).unwrap()
  self.bindings
  .get(client_id)
  .unwrap()
  .set(filter, {
    ..prior,
    no_local,
    retain_as_published,
    retain_handling,
    subscription_identifier,
  })
  added
}

///|
fn SubscriptionIndex::restore_binding(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
  binding : SubscriptionBinding,
) -> Unit {
  ignore(
    self.put_v5(
      client_id,
      binding.filter,
      binding.qos,
      binding.no_local,
      binding.retain_as_published,
      binding.retain_handling,
      binding.subscription_identifier,
    ),
  )
  self.bindings.get(client_id).unwrap().set(binding.filter, binding)
}

///|
pub fn SubscriptionIndex::binding(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
  filter : @topic.TopicFilter,
) -> SubscriptionBinding? {
  match self.bindings.get(client_id) {
    Some(values) => values.get(filter)
    None => None
  }
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
          let bindings = self.bindings.get(client_id).unwrap()
          bindings.remove(filter)
          if bindings.length() == 0 {
            self.bindings.remove(client_id)
          }
          let clients = self.by_filter.get(filter).unwrap()
          clients.remove(client_id)
          if clients.length() == 0 {
            self.by_filter.remove(filter)
          }
          if self.policy_slots is Some(slots) &&
            !slots.untrack(client_id, filter) {
            abort("core policy subscription identity missing")
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
/// Returns a sorted snapshot for BrokerState invariant validation.
fn SubscriptionIndex::client_ids(
  self : SubscriptionIndex,
) -> Array[@session.ClientId] {
  let result = self.by_client.keys().collect()
  result.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.value(), right.value())
  })
  result
}

///|
fn SubscriptionIndex::records_for(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
) -> Array[SubscriptionRecord] {
  let result : Array[SubscriptionRecord] = []
  match self.by_client.get(client_id) {
    Some(filters) =>
      for filter, qos in filters {
        result.push({ filter, qos })
      }
    None => ()
  }
  result.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.filter.value(), right.filter.value())
  })
  result
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
  if self.count < 0 {
    return false
  }
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
  let mut reverse_count = 0
  for entry in self.by_client {
    let (client_id, filters) = entry
    if filters.length() == 0 {
      return false
    }
    for entry in filters {
      let (filter, qos) = entry
      match self.by_filter.get(filter) {
        Some(clients) =>
          match clients.get(client_id) {
            Some(forward_qos) if forward_qos == qos =>
              reverse_count = reverse_count + 1
            _ => return false
          }
        None => return false
      }
    }
  }
  if self.bindings.length() != self.by_client.length() ||
    self.next_identity < 1L {
    return false
  }
  let seen_identities : Map[Int64, Bool] = Map([])
  let mut binding_count = 0
  for client_id, bindings in self.bindings {
    let filters = match self.by_client.get(client_id) {
      Some(value) => value
      None => return false
    }
    if bindings.length() != filters.length() {
      return false
    }
    for filter, binding in bindings {
      if binding.filter != filter ||
        filters.get(filter) != Some(binding.qos) ||
        binding.identity < 1L ||
        binding.identity >= self.next_identity ||
        binding.retain_handling < 0 ||
        binding.retain_handling > 2 ||
        seen_identities.contains(binding.identity) {
        return false
      }
      seen_identities.set(binding.identity, true)
      binding_count += 1
    }
  }
  forward_count == self.count &&
  reverse_count == self.count &&
  binding_count == self.count &&
  forward_count == reverse_count &&
  (
    self.policy_slots is None ||
    self.policy_slots.unwrap().check_invariants(self.count)
  )
}

///|
fn SubscriptionIndex::cost_for(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
) -> Int64 {
  let mut cost = 0L
  if self.by_client.get(client_id) is Some(filters) {
    for filter, _ in filters {
      cost = @budget.checked_add(
        cost,
        @budget.subscription_cost(filter.value()),
      ).unwrap()
    }
  }
  cost
}

///|
pub fn SubscriptionIndex::matches_v5(
  self : SubscriptionIndex,
  topic : @topic.TopicName,
  publisher_client_id : @session.ClientId?,
  retain_from_publish : Bool,
  retained_replay? : Bool = false,
) -> Array[SubscriptionDeliveryMatch] {
  let result : Array[SubscriptionDeliveryMatch] = []
  for client_id, bindings in self.bindings {
    let matched : Array[SubscriptionBinding] = []
    for filter, binding in bindings {
      if filter.matches(topic) &&
        !(binding.no_local && publisher_client_id == Some(client_id)) {
        matched.push(binding)
      }
    }
    matched.sort_by(fn(left, right) {
      if left.identity < right.identity {
        -1
      } else if left.identity > right.identity {
        1
      } else {
        0
      }
    })
    let mut normal_qos : @session.DeliveryQoS? = None
    let normal_ids : Array[Int] = []
    let mut retained_qos : @session.DeliveryQoS? = None
    let retained_ids : Array[Int] = []
    for binding in matched {
      let final_retain = retained_replay ||
        (retain_from_publish && binding.retain_as_published)
      if final_retain {
        retained_qos = Some(
          match retained_qos {
            Some(previous) => @session.max_qos(previous, binding.qos)
            None => binding.qos
          },
        )
        if binding.subscription_identifier is Some(id) {
          retained_ids.push(id)
        }
      } else {
        normal_qos = Some(
          match normal_qos {
            Some(previous) => @session.max_qos(previous, binding.qos)
            None => binding.qos
          },
        )
        if binding.subscription_identifier is Some(id) {
          normal_ids.push(id)
        }
      }
    }
    if normal_qos is Some(qos) {
      result.push({
        client_id,
        qos,
        retain: false,
        subscription_identifiers: normal_ids,
      })
    }
    if retained_qos is Some(qos) {
      result.push({
        client_id,
        qos,
        retain: true,
        subscription_identifiers: retained_ids,
      })
    }
  }
  result.sort_by(fn(left, right) {
    let names = compare_utf8_for_sort(
      left.client_id.value(),
      right.client_id.value(),
    )
    if names != 0 {
      names
    } else if left.retain == right.retain {
      0
    } else if left.retain {
      1
    } else {
      -1
    }
  })
  result
}

///|
pub fn SubscriptionIndex::bindings_for(
  self : SubscriptionIndex,
  client_id : @session.ClientId,
) -> Array[SubscriptionBinding] {
  let result : Array[SubscriptionBinding] = []
  if self.bindings.get(client_id) is Some(values) {
    for _, binding in values {
      result.push(binding)
    }
  }
  result.sort_by(fn(left, right) {
    if left.identity < right.identity {
      -1
    } else if left.identity > right.identity {
      1
    } else {
      0
    }
  })
  result
}

///|
pub fn SubscriptionIndex::next_identity(self : SubscriptionIndex) -> Int64 {
  self.next_identity
}

///|
pub fn SubscriptionIndex::ensure_next_identity(
  self : SubscriptionIndex,
  value : Int64,
) -> Bool {
  if value < 1L {
    return false
  }
  for _, bindings in self.bindings {
    for _, binding in bindings {
      if binding.identity >= value {
        return false
      }
    }
  }
  self.next_identity = value
  true
}
