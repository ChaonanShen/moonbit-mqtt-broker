///|
pub struct DurableAccumulatorV5 {
  mut snapshot : BrokerSnapshotV5
}

///|
pub fn DurableAccumulatorV5::new(
  snapshot : BrokerSnapshotV5,
) -> DurableAccumulatorV5 {
  { snapshot, }
}

///|
pub fn DurableAccumulatorV5::snapshot(
  self : DurableAccumulatorV5,
) -> BrokerSnapshotV5 {
  self.snapshot
}

///|
pub fn DurableAccumulatorV5::apply(
  self : DurableAccumulatorV5,
  delta : DurableDeltaV5,
) -> Result[Unit, SnapshotError] {
  let before = self.snapshot
  let sessions = before.sessions.copy()
  let groups = before.groups.copy()
  let retained = before.retained.copy()
  let wills = before.wills.copy()
  let mut clock_floor = before.clock_floor_wall_ms
  let mut next_session = before.next_session_incarnation
  let mut next_subscription = before.next_subscription_identity
  let mut next_delivery = before.next_delivery_id
  let mut next_group = before.next_group_id
  let mut next_will = before.next_will_id
  let mut next_retained = before.next_retained_revision
  if delta.new_clock_floor is Some(value) {
    if value < clock_floor {
      return Err(InvalidState("clock floor regressed"))
    }
    clock_floor = value
  }
  let seen_floors : Map[Int, Bool] = Map([])
  for item in delta.id_floors {
    if seen_floors.contains(item.kind) || item.new_floor < 1L {
      return Err(InvalidState("duplicate or invalid id floor"))
    }
    seen_floors.set(item.kind, true)
    match item.kind {
      1 => if item.new_floor > next_session { next_session = item.new_floor }
      2 =>
        if item.new_floor > next_subscription {
          next_subscription = item.new_floor
        }
      3 => if item.new_floor > next_delivery { next_delivery = item.new_floor }
      4 => if item.new_floor > next_group { next_group = item.new_floor }
      5 => if item.new_floor > next_will { next_will = item.new_floor }
      6 => if item.new_floor > next_retained { next_retained = item.new_floor }
      _ => return Err(InvalidState("unknown id floor kind"))
    }
  }
  for deletion in delta.session_deletes {
    let mut found = false
    let remaining : Array[SnapshotSessionV5] = []
    for value in sessions {
      if value.client_id == deletion.client_id {
        if found ||
          value.incarnation != deletion.expected_incarnation ||
          value.state_revision != deletion.expected_revision {
          return Err(InvalidState("session delete conflict"))
        }
        found = true
      } else {
        remaining.push(value)
      }
    }
    if !found {
      return Err(InvalidState("missing session delete target"))
    }
    sessions.clear()
    sessions.append(remaining)
  }
  for put in delta.session_puts {
    let mut found = false
    for index in 0..<sessions.length() {
      if sessions[index].client_id == put.session.client_id {
        if found ||
          sessions[index].incarnation != put.expected_incarnation ||
          sessions[index].state_revision != put.expected_revision ||
          put.session.state_revision <= put.expected_revision {
          return Err(InvalidState("session put conflict"))
        }
        sessions[index] = put.session
        found = true
      }
    }
    if !found {
      if put.expected_incarnation != 0L || put.expected_revision != 0L {
        return Err(InvalidState("new session expected nonzero state"))
      }
      sessions.push(put.session)
    }
  }
  for deletion in delta.group_deletes {
    let mut found = false
    let remaining : Array[SnapshotGroupV5] = []
    for value in groups {
      if value.id == deletion.id {
        if found ||
          value.incarnation != deletion.expected_incarnation ||
          value.revision != deletion.expected_revision {
          return Err(InvalidState("group delete conflict"))
        }
        found = true
      } else {
        remaining.push(value)
      }
    }
    if !found {
      return Err(InvalidState("missing group delete target"))
    }
    groups.clear()
    groups.append(remaining)
  }
  for put in delta.group_puts {
    let mut found = false
    for index in 0..<groups.length() {
      if groups[index].id == put.group.id {
        if found ||
          groups[index].incarnation != put.expected_incarnation ||
          groups[index].revision != put.expected_revision ||
          put.group.revision <= put.expected_revision {
          return Err(InvalidState("group put conflict"))
        }
        groups[index] = put.group
        found = true
      }
    }
    if !found {
      if put.expected_incarnation != 0L || put.expected_revision != 0L {
        return Err(InvalidState("new group expected nonzero state"))
      }
      groups.push(put.group)
    }
  }
  for deletion in delta.retained_deletes {
    let mut found = false
    let remaining : Array[SnapshotRetainedV5] = []
    for value in retained {
      if value.message.topic == deletion.topic {
        if found || value.revision != deletion.expected_revision {
          return Err(InvalidState("retained delete conflict"))
        }
        found = true
      } else {
        remaining.push(value)
      }
    }
    if !found {
      return Err(InvalidState("missing retained delete target"))
    }
    retained.clear()
    retained.append(remaining)
  }
  for put in delta.retained_puts {
    let mut found = false
    for index in 0..<retained.length() {
      if retained[index].message.topic == put.retained.message.topic {
        if found ||
          retained[index].revision != put.expected_revision ||
          put.retained.revision <= put.expected_revision {
          return Err(InvalidState("retained put conflict"))
        }
        retained[index] = put.retained
        found = true
      }
    }
    if !found {
      if put.expected_revision != 0L {
        return Err(InvalidState("new retained expected revision"))
      }
      retained.push(put.retained)
    }
  }
  for deletion in delta.will_deletes {
    let mut found = false
    let remaining : Array[SnapshotWillV5] = []
    for value in wills {
      if value.id == deletion.id {
        if found || value.revision != deletion.expected_revision {
          return Err(InvalidState("Will delete conflict"))
        }
        found = true
      } else {
        remaining.push(value)
      }
    }
    if !found {
      return Err(InvalidState("missing Will delete target"))
    }
    wills.clear()
    wills.append(remaining)
  }
  for put in delta.will_puts {
    let mut found = false
    for index in 0..<wills.length() {
      if wills[index].id == put.will.id {
        if found ||
          wills[index].revision != put.expected_revision ||
          put.will.revision <= put.expected_revision {
          return Err(InvalidState("Will put conflict"))
        }
        wills[index] = put.will
        found = true
      }
    }
    if !found {
      if put.expected_revision != 0L {
        return Err(InvalidState("new Will expected revision"))
      }
      wills.push(put.will)
    }
  }
  sessions.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.client_id, right.client_id)
  })
  groups.sort_by(fn(left, right) {
    if left.id < right.id {
      -1
    } else if left.id > right.id {
      1
    } else {
      0
    }
  })
  retained.sort_by(fn(left, right) {
    compare_utf8_for_sort(left.message.topic, right.message.topic)
  })
  wills.sort_by(fn(left, right) {
    if left.id < right.id {
      -1
    } else if left.id > right.id {
      1
    } else {
      0
    }
  })
  self.snapshot = {
    clock_floor_wall_ms: clock_floor,
    next_session_incarnation: next_session,
    next_subscription_identity: next_subscription,
    next_delivery_id: next_delivery,
    next_group_id: next_group,
    next_will_id: next_will,
    next_retained_revision: next_retained,
    groups,
    sessions,
    retained,
    wills,
  }
  Ok(())
}
