///|
pub(all) enum DurablePolicyChange {
  DropSubscription(String)
  DropPendingHead(String, Int, Int)
} derive(Eq)

///|
pub(all) struct DurableReconcileDelta {
  client_id : String
  expected_generation : Int64
  change : DurablePolicyChange
} derive(Eq)

///|
pub(all) struct DurableSessionPut {
  expected_generation : Int64
  generation : Int64
  session : SnapshotSessionV3
} derive(Eq, Debug)

///|
pub(all) struct DurableSessionDelete {
  client_id : String
  expected_generation : Int64
} derive(Eq, Debug)

///|
pub(all) struct DurableDelta {
  session_puts : Array[DurableSessionPut]
  session_deletes : Array[DurableSessionDelete]
  retained_puts : Array[SnapshotRetainedV3]
  retained_deletes : Array[String]
} derive(Eq, Debug)

///|
pub fn DurableDelta::empty() -> DurableDelta {
  {
    session_puts: [],
    session_deletes: [],
    retained_puts: [],
    retained_deletes: [],
  }
}

///|
pub struct DurableAccumulator {
  config : BrokerConfig
  sessions : Map[String, DurableSessionPut]
  retained : Map[String, SnapshotRetainedV3]
  mut bytes : Int64
  max_bytes : Int64
}

///|
fn copy_durable_message(message : SnapshotMessageV3) -> SnapshotMessageV3 {
  { ..message, payload: Bytes::from_array(message.payload.to_array()) }
}

///|
fn copy_durable_session(value : DurableSessionPut) -> DurableSessionPut {
  let session = value.session
  {
    ..value,
    session: {
      ..session,
      subscriptions: session.subscriptions.copy(),
      inbound_qos2: session.inbound_qos2.copy(),
      inflight: session.inflight.map(item => {
        ..item,
        message: item.message.map(copy_durable_message),
      }),
      pending: session.pending.map(copy_durable_message),
    },
  }
}

///|
fn copy_durable_retained(value : SnapshotRetainedV3) -> SnapshotRetainedV3 {
  { ..value, payload: Bytes::from_array(value.payload.to_array()) }
}

///|
fn durable_checked_add(a : Int64, b : Int64) -> Result[Int64, SnapshotError] {
  match @budget.checked_add(a, b) {
    Ok(value) => Ok(value)
    Err(_) => Err(LimitExceeded("WAL state byte count overflow"))
  }
}

///|
fn durable_session_cost(
  value : SnapshotSessionV3,
) -> Result[Int64, SnapshotError] {
  let mut total = @budget.identity_cost(value.client_id, value.owner_principal)
  for subscription in value.subscriptions {
    total = match
      durable_checked_add(total, @budget.subscription_cost(subscription.filter)) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  for item in value.inflight {
    let cost = match item.message {
      None => 64L
      Some(message) =>
        match
          @budget.message_cost(
            message.topic,
            message.payload.length().to_int64(),
          ) {
          Ok(value) => value
          Err(_) => return Err(LimitExceeded("WAL inflight byte overflow"))
        }
    }
    total = match durable_checked_add(total, cost) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  for message in value.pending {
    let cost = match
      @budget.message_cost(message.topic, message.payload.length().to_int64()) {
      Ok(value) => value
      Err(_) => return Err(LimitExceeded("WAL pending byte overflow"))
    }
    total = match durable_checked_add(total, cost) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  let inbound_cost = match
    @budget.checked_mul(value.inbound_qos2.length().to_int64(), 64L) {
    Ok(value) => value
    Err(_) => return Err(LimitExceeded("WAL inbound byte overflow"))
  }
  durable_checked_add(total, inbound_cost)
}

///|
fn durable_retained_cost(
  value : SnapshotRetainedV3,
) -> Result[Int64, SnapshotError] {
  match @budget.message_cost(value.topic, value.payload.length().to_int64()) {
    Ok(result) => Ok(result)
    Err(_) => Err(LimitExceeded("WAL retained byte overflow"))
  }
}

///|
pub fn DurableAccumulator::new(
  config : BrokerConfig,
  snapshot : BrokerSnapshotV3,
  generations : Array[Int64],
) -> Result[DurableAccumulator, SnapshotError] {
  if snapshot.version != 3 || snapshot.sessions.length() != generations.length() {
    return Err(InvalidState("invalid WAL checkpoint identity count"))
  }
  match BrokerState::from_snapshot(config, snapshot) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let sessions : Map[String, DurableSessionPut] = Map([])
  for index in 0..<snapshot.sessions.length() {
    let session = snapshot.sessions[index]
    let generation = generations[index]
    if generation < 1L || sessions.contains(session.client_id) {
      return Err(InvalidState("invalid WAL session generation"))
    }
    sessions.set(
      session.client_id,
      copy_durable_session({ expected_generation: 0L, generation, session }),
    )
  }
  let retained : Map[String, SnapshotRetainedV3] = Map([])
  for value in snapshot.retained {
    retained.set(value.topic, copy_durable_retained(value))
  }
  let mut bytes = 0L
  for _, item in sessions {
    bytes = match durable_session_cost(item.session) {
      Ok(cost) =>
        match durable_checked_add(bytes, cost) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      Err(error) => return Err(error)
    }
  }
  for _, item in retained {
    bytes = match durable_retained_cost(item) {
      Ok(cost) =>
        match durable_checked_add(bytes, cost) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      Err(error) => return Err(error)
    }
  }
  let resources = config.resources()
  let max_bytes = resources.get("max_managed_bytes_total") -
    resources.get("control_reserve_bytes")
  if bytes > max_bytes {
    return Err(LimitExceeded("WAL state byte limit exceeded"))
  }
  Ok({ config, sessions, retained, bytes, max_bytes })
}

///|
pub fn DurableAccumulator::apply(
  self : DurableAccumulator,
  delta : DurableDelta,
) -> Result[Unit, SnapshotError] {
  let seen_sessions : Map[String, Bool] = Map([])
  let seen_retained : Map[String, Bool] = Map([])
  let mut next_sessions = self.sessions.length()
  let mut next_retained = self.retained.length()
  for deletion in delta.session_deletes {
    if seen_sessions.contains(deletion.client_id) ||
      self.sessions.get(deletion.client_id) is None ||
      self.sessions.get(deletion.client_id).unwrap().generation !=
      deletion.expected_generation {
      return Err(InvalidState("WAL session delete generation mismatch"))
    }
    seen_sessions.set(deletion.client_id, true)
    next_sessions -= 1
  }
  for put in delta.session_puts {
    let id = put.session.client_id
    if seen_sessions.contains(id) ||
      put.generation < 1L ||
      put.expected_generation < 0L {
      return Err(InvalidState("WAL session put conflict"))
    }
    let existing = self.sessions.get(id)
    if existing is Some(value) {
      if put.expected_generation != value.generation ||
        put.generation < value.generation {
        return Err(InvalidState("WAL session put generation mismatch"))
      }
    } else if put.expected_generation != 0L {
      return Err(InvalidState("WAL session create generation mismatch"))
    } else {
      next_sessions += 1
    }
    seen_sessions.set(id, true)
  }
  for topic in delta.retained_deletes {
    if seen_retained.contains(topic) || !self.retained.contains(topic) {
      return Err(InvalidState("WAL retained delete conflict"))
    }
    seen_retained.set(topic, true)
    next_retained -= 1
  }
  for put in delta.retained_puts {
    if seen_retained.contains(put.topic) {
      return Err(InvalidState("WAL retained put conflict"))
    }
    if !self.retained.contains(put.topic) {
      next_retained += 1
    }
    seen_retained.set(put.topic, true)
  }
  if next_sessions > self.config.max_sessions() ||
    next_retained > self.config.max_retained_messages() {
    return Err(LimitExceeded("WAL state count limit exceeded"))
  }
  if !delta.session_puts.is_empty() || !delta.retained_puts.is_empty() {
    let changed : BrokerSnapshotV3 = {
      version: 3,
      sessions: delta.session_puts.map(item => item.session),
      retained: delta.retained_puts,
    }
    match BrokerState::from_snapshot(self.config, changed) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let mut next_bytes = self.bytes
  for deletion in delta.session_deletes {
    let cost = match
      durable_session_cost(
        self.sessions.get(deletion.client_id).unwrap().session,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    next_bytes -= cost
  }
  for put in delta.session_puts {
    if self.sessions.get(put.session.client_id) is Some(old) {
      let cost = match durable_session_cost(old.session) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      next_bytes -= cost
    }
    let cost = match durable_session_cost(put.session) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    next_bytes = match durable_checked_add(next_bytes, cost) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  for topic in delta.retained_deletes {
    let cost = match durable_retained_cost(self.retained.get(topic).unwrap()) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    next_bytes -= cost
  }
  for put in delta.retained_puts {
    if self.retained.get(put.topic) is Some(old) {
      let cost = match durable_retained_cost(old) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      next_bytes -= cost
    }
    let cost = match durable_retained_cost(put) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    next_bytes = match durable_checked_add(next_bytes, cost) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  if next_bytes < 0L || next_bytes > self.max_bytes {
    return Err(LimitExceeded("WAL state byte limit exceeded"))
  }
  for deletion in delta.session_deletes {
    self.sessions.remove(deletion.client_id)
  }
  for put in delta.session_puts {
    self.sessions.set(put.session.client_id, copy_durable_session(put))
  }
  for topic in delta.retained_deletes {
    self.retained.remove(topic)
  }
  for put in delta.retained_puts {
    self.retained.set(put.topic, copy_durable_retained(put))
  }
  self.bytes = next_bytes
  Ok(())
}

///|

///|
/// A local security cleanup record updates only the named subscription or
/// pending head. It never clones a whole large Session into one WAL delta.
pub fn DurableAccumulator::apply_reconcile(
  self : DurableAccumulator,
  delta : DurableReconcileDelta,
) -> Result[Unit, SnapshotError] {
  let existing = match self.sessions.get(delta.client_id) {
    Some(value) if value.generation == delta.expected_generation => value
    _ => return Err(InvalidState("policy reconcile Session generation changed"))
  }
  let session = existing.session
  let (replacement, released) = match delta.change {
    DropSubscription(filter) => {
      if !session.subscriptions.any(item => item.filter == filter) {
        return Err(InvalidState("policy reconcile subscription missing"))
      }
      let remaining = session.subscriptions.filter(item => item.filter != filter)
      (
        { ..session, subscriptions: remaining },
        @budget.subscription_cost(filter),
      )
    }
    DropPendingHead(topic, qos, payload_bytes) => {
      if session.pending.is_empty() ||
        session.pending[0].topic != topic ||
        session.pending[0].qos != qos ||
        session.pending[0].payload.length() != payload_bytes {
        return Err(InvalidState("policy reconcile pending head changed"))
      }
      let remaining = session.pending[1:].to_owned()
      let cost = match @budget.message_cost(topic, payload_bytes.to_int64()) {
        Ok(value) => value
        Err(_) => return Err(LimitExceeded("policy reconcile message cost"))
      }
      ({ ..session, pending: remaining }, cost)
    }
  }
  if released < 0L || released > self.bytes {
    return Err(InvalidState("policy reconcile byte count"))
  }
  self.sessions.set(delta.client_id, { ..existing, session: replacement })
  self.bytes -= released
  Ok(())
}

///|
pub fn DurableAccumulator::export_snapshot(
  self : DurableAccumulator,
) -> (BrokerSnapshotV3, Array[Int64]) {
  let ids = self.sessions.keys().collect()
  ids.sort_by(compare_utf8_for_sort)
  let sessions : Array[SnapshotSessionV3] = []
  let generations : Array[Int64] = []
  for id in ids {
    let item = self.sessions.get(id).unwrap()
    sessions.push(copy_durable_session(item).session)
    generations.push(item.generation)
  }
  let topics = self.retained.keys().collect()
  topics.sort_by(compare_utf8_for_sort)
  let retained : Array[SnapshotRetainedV3] = []
  for topic in topics {
    retained.push(copy_durable_retained(self.retained.get(topic).unwrap()))
  }
  ({ version: 3, sessions, retained }, generations)
}
