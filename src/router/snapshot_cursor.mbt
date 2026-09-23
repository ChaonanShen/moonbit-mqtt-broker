///|
pub struct SnapshotSessionBuilder {
  session : @session.ClientSession
  snapshot : SnapshotSessionV3
  subscription_iter : Iter[(@topic.TopicFilter, @session.DeliveryQoS)]
  mut subscription_pending : (@topic.TopicFilter, @session.DeliveryQoS)?
  mut subscriptions_done : Bool
  mut inbound_index : Int
  mut inflight_index : Int
  mut pending_index : Int
}

///|
pub struct SnapshotExportCursor {
  broker : BrokerState
  generations : Map[@session.ClientId, Int64]
  session_iter : Iter[(@session.ClientId, @session.ClientSession)]
  retained_iter : Iter[(@topic.TopicName, RetainedMessage)]
  mut retained_pending : (@topic.TopicName, RetainedMessage)?
  mut current : SnapshotSessionBuilder?
  sessions : Array[SnapshotSessionV3]
  retained : Array[SnapshotRetainedV3]
  identities : Array[Int64]
  mut phase : Int
}

///|
pub fn BrokerState::start_snapshot_export(
  self : BrokerState,
  generations : Map[@session.ClientId, Int64],
) -> SnapshotExportCursor {
  {
    broker: self,
    generations,
    session_iter: self.sessions.iter(),
    retained_iter: self.retained.messages.iter(),
    retained_pending: None,
    current: None,
    sessions: [],
    retained: [],
    identities: [],
    phase: 0,
  }
}

///|
fn SnapshotExportCursor::begin_session(
  self : SnapshotExportCursor,
  client_id : @session.ClientId,
  session : @session.ClientSession,
) -> Result[Unit, SnapshotError] {
  let generation = match self.generations.get(client_id) {
    Some(value) if value > 0L => value
    _ => return Err(InvalidState("snapshot export missing session generation"))
  }
  let subscription_iter = match
    self.broker.subscriptions.by_client.get(client_id) {
    Some(filters) => filters.iter()
    None => {
      let empty : Map[@topic.TopicFilter, @session.DeliveryQoS] = Map([])
      empty.iter()
    }
  }
  self.identities.push(generation)
  self.current = Some({
    session,
    snapshot: {
      client_id: client_id.value(),
      owner_principal: session.owner().storage_value(),
      detached_at_ms: session.detached_at_ms().unwrap_or(0L),
      next_packet_id: session.next_packet_id(),
      subscriptions: [],
      inbound_qos2: [],
      inflight: [],
      pending: [],
    },
    subscription_iter,
    subscription_pending: None,
    subscriptions_done: false,
    inbound_index: 0,
    inflight_index: 0,
    pending_index: 0,
  })
  Ok(())
}

///|
/// Each call copies at most max_items objects and max_bytes charged payload
/// bytes. One message larger than max_bytes is rejected before copying.
pub fn SnapshotExportCursor::step(
  self : SnapshotExportCursor,
  max_items : Int,
  max_bytes : Int64,
) -> Result[Bool, SnapshotError] {
  if max_items < 1 || max_bytes < 1L {
    return Err(InvalidState("invalid snapshot export slice"))
  }
  let mut items = 0
  let mut bytes = 0L
  while items < max_items && bytes < max_bytes && self.phase < 2 {
    if self.phase == 0 {
      if self.current is None {
        match self.session_iter.next() {
          None => {
            self.phase = 1
            continue
          }
          Some((client_id, session)) => {
            items += 1
            if session.mode() == @session.Persistent {
              match self.begin_session(client_id, session) {
                Ok(_) => ()
                Err(error) => return Err(error)
              }
            }
            continue
          }
        }
      }
      let builder = self.current.unwrap()
      if !builder.subscriptions_done {
        let next = match builder.subscription_pending {
          Some(value) => Some(value)
          None => builder.subscription_iter.next()
        }
        match next {
          None => {
            builder.subscriptions_done = true
            continue
          }
          Some((filter, qos)) => {
            let cost = @budget.subscription_cost(filter.value())
            if cost > max_bytes {
              return Err(LimitExceeded("subscription exceeds export slice"))
            }
            if cost > max_bytes - bytes {
              builder.subscription_pending = Some((filter, qos))
              break
            }
            builder.subscription_pending = None
            builder.snapshot.subscriptions.push({
              filter: filter.value(),
              qos: snapshot_qos(qos),
            })
            items += 1
            bytes += cost
            continue
          }
        }
      }
      if builder.inbound_index < builder.session.inbound_qos2_count() {
        if 64L > max_bytes - bytes {
          break
        }
        builder.snapshot.inbound_qos2.push(
          builder.session
          .inbound_qos2_item(builder.inbound_index)
          .unwrap()
          .value(),
        )
        builder.inbound_index += 1
        items += 1
        bytes += 64L
        continue
      }
      if builder.inflight_index < builder.session.inflight_count() {
        let cost = builder.session
          .inflight_item_cost(builder.inflight_index)
          .unwrap()
        if cost > max_bytes {
          return Err(LimitExceeded("inflight item exceeds export slice"))
        }
        if cost > max_bytes - bytes {
          break
        }
        let item = builder.session
          .inflight_item(builder.inflight_index)
          .unwrap()
        builder.snapshot.inflight.push({
          packet_id: item.packet_id.value(),
          phase: match item.phase {
            AwaitPuback => 1
            AwaitPubrec => 2
            AwaitPubcomp => 3
          },
          message: item.message.map(snapshot_message),
        })
        builder.inflight_index += 1
        items += 1
        bytes += cost
        continue
      }
      if builder.pending_index < builder.session.pending_count() {
        let cost = builder.session
          .pending_item_cost(builder.pending_index)
          .unwrap()
        if cost > max_bytes {
          return Err(LimitExceeded("pending item exceeds export slice"))
        }
        if cost > max_bytes - bytes {
          break
        }
        let message = builder.session
          .pending_item(builder.pending_index)
          .unwrap()
        builder.snapshot.pending.push(snapshot_message(message))
        builder.pending_index += 1
        items += 1
        bytes += cost
        continue
      }
      self.sessions.push(builder.snapshot)
      self.current = None
      items += 1
      continue
    }
    let next = match self.retained_pending {
      Some(value) => Some(value)
      None => self.retained_iter.next()
    }
    match next {
      None => self.phase = 2
      Some((topic, message)) => {
        let cost = @budget.message_cost(
          topic.value(),
          message.payload.length().to_int64(),
        ).unwrap()
        if cost > max_bytes {
          return Err(LimitExceeded("retained item exceeds export slice"))
        }
        if cost > max_bytes - bytes {
          self.retained_pending = Some((topic, message))
          break
        }
        self.retained_pending = None
        self.retained.push({
          topic: topic.value(),
          payload: copy_router_bytes(message.payload),
          qos: snapshot_qos(message.qos),
        })
        items += 1
        bytes += cost
      }
    }
  }
  Ok(self.phase == 2)
}

///|
pub fn SnapshotExportCursor::finish(
  self : SnapshotExportCursor,
) -> Result[(BrokerSnapshotV3, Array[Int64]), SnapshotError] {
  if self.phase != 2 ||
    self.current is Some(_) ||
    self.sessions.length() != self.identities.length() {
    return Err(InvalidState("snapshot export is incomplete"))
  }
  Ok(
    (
      { version: 3, sessions: self.sessions, retained: self.retained },
      self.identities,
    ),
  )
}
