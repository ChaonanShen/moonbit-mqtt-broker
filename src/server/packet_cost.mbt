///|
fn packet_cost(packet : @protocol.Packet) -> Int64 {
  let mut cost = 128L
  match packet {
    Connect(c) => {
      cost += @budget.utf8_bytes(c.client_id)
      if c.username is Some(u) {
        cost += @budget.utf8_bytes(u)
      }
      if c.password is Some(p) {
        cost += p.length().to_int64()
      }
      if c.will is Some(w) {
        cost += @budget.utf8_bytes(w.topic) +
          w.payload.length().to_int64() +
          96L
      }
    }
    Publish(p) =>
      cost += @budget.utf8_bytes(p.topic) + p.payload.length().to_int64()
    Subscribe(s) =>
      for entry in s.subscriptions {
        cost += @budget.utf8_bytes(entry.topic_filter) + 64L
      }
    Unsubscribe(s) =>
      for filter in s.topic_filters {
        cost += @budget.utf8_bytes(filter) + 64L
      }
    Suback(s) => cost += s.return_codes.length().to_int64()
    _ => ()
  }
  cost
}

///|
fn decode_cost_bound(frame : Bytes) -> Int64 {
  let size = frame.length().to_int64()
  let kind = frame[0].to_int() >> 4
  if kind == 8 || kind == 10 {
    size * 33L + 128L
  } else {
    size + 256L
  }
}

///|
/// Conservative complete wire size, computed without encoding or copying.
fn wire_cost_bound(packet : @protocol.Packet) -> Int64 {
  match packet {
    Publish(p) =>
      9L + @budget.utf8_bytes(p.topic) + p.payload.length().to_int64()
    Connect(c) => {
      let mut size = 17L + @budget.utf8_bytes(c.client_id)
      if c.username is Some(u) {
        size += 2L + @budget.utf8_bytes(u)
      }
      if c.password is Some(p) {
        size += 2L + p.length().to_int64()
      }
      if c.will is Some(w) {
        size += 4L + @budget.utf8_bytes(w.topic) + w.payload.length().to_int64()
      }
      size
    }
    Subscribe(s) => {
      let mut size = 7L
      for item in s.subscriptions {
        size += 3L + @budget.utf8_bytes(item.topic_filter)
      }
      size
    }
    Unsubscribe(s) => {
      let mut size = 7L
      for filter in s.topic_filters {
        size += 2L + @budget.utf8_bytes(filter)
      }
      size
    }
    Suback(s) => 7L + s.return_codes.length().to_int64()
    Pingreq | Pingresp | Disconnect => 2L
    _ => 4L
  }
}

///|
fn control_packet(packet : @protocol.Packet) -> Bool {
  match packet {
    Publish(_) | Connect(_) | Subscribe(_) | Unsubscribe(_) => false
    _ => true
  }
}

///|
fn control_frame(frame : Bytes) -> Bool {
  let kind = frame[0].to_int() >> 4
  kind != 1 && kind != 3 && kind != 8 && kind != 10
}
