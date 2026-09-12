///|
let disk_magic : Bytes = b"MBMQTT01"

///|
let disk_header_bytes : Int = 24

///|
fn encode_message(
  writer : BinaryWriter,
  message : @router.SnapshotMessageV3,
  version : Int,
) -> Unit raise PersistenceError {
  if message.qos < 1 || message.qos > (if version == 3 { 2 } else { 1 }) {
    raise InvalidValue(field="message-qos", offset=writer.bytes.length())
  }
  writer.write_string(message.topic)
  writer.write_bytes(message.payload)
  writer.write_u8(if message.retain { 1 } else { 0 }, "message-retain")
  if version == 3 {
    writer.write_u8(message.qos, "message-qos")
  }
}

///|
fn encode_payload(
  snapshot : @router.BrokerSnapshotV3,
  max_bytes : Int,
) -> Bytes raise PersistenceError {
  let writer = BinaryWriter::new(max_bytes~)
  writer.write_u32(snapshot.version, "snapshot-model-version")
  if snapshot.version != 1 && snapshot.version != 2 && snapshot.version != 3 {
    raise InvalidValue(field="snapshot-model-version", offset=0)
  }
  writer.write_u32(snapshot.sessions.length(), "session-count")
  for session in snapshot.sessions {
    writer.write_string(session.client_id)
    if snapshot.version >= 2 {
      writer.write_string(session.owner_principal)
      if session.detached_at_ms < 0L {
        raise InvalidValue(field="detached-at-ms", offset=writer.bytes.length())
      }
      writer.write_string(session.detached_at_ms.to_string())
    }
    if session.next_packet_id < 1 || session.next_packet_id > 65535 {
      raise InvalidValue(field="next-packet-id", offset=writer.bytes.length())
    }
    writer.write_u16(session.next_packet_id, "next-packet-id")
    writer.write_u32(session.subscriptions.length(), "subscription-count")
    for subscription in session.subscriptions {
      writer.write_string(subscription.filter)
      if subscription.qos < 0 ||
        subscription.qos > (if snapshot.version == 3 { 2 } else { 1 }) {
        raise InvalidValue(
          field="subscription-qos",
          offset=writer.bytes.length(),
        )
      }
      writer.write_u8(subscription.qos, "subscription-qos")
    }
    if snapshot.version == 3 {
      writer.write_u32(session.inbound_qos2.length(), "inbound-qos2-count")
      for id in session.inbound_qos2 {
        if id < 1 || id > 65535 {
          raise InvalidValue(
            field="inbound-packet-id",
            offset=writer.bytes.length(),
          )
        }
        writer.write_u16(id, "inbound-packet-id")
      }
    } else if !session.inbound_qos2.is_empty() {
      raise InvalidValue(
        field="legacy-inbound-qos2",
        offset=writer.bytes.length(),
      )
    }
    writer.write_u32(session.inflight.length(), "inflight-count")
    for item in session.inflight {
      if item.packet_id < 1 || item.packet_id > 65535 {
        raise InvalidValue(field="packet-id", offset=writer.bytes.length())
      }
      writer.write_u16(item.packet_id, "packet-id")
      if item.phase < 1 ||
        item.phase > 3 ||
        (snapshot.version < 3 && item.phase != 1) {
        raise InvalidValue(field="outbound-phase", offset=writer.bytes.length())
      }
      if snapshot.version == 3 {
        writer.write_u8(item.phase, "outbound-phase")
      }
      match item.message {
        Some(message) => {
          if item.phase == 3 || message.qos != item.phase {
            raise InvalidValue(
              field="phase-message",
              offset=writer.bytes.length(),
            )
          }
          encode_message(writer, message, snapshot.version)
        }
        None =>
          if item.phase != 3 {
            raise InvalidValue(
              field="missing-message",
              offset=writer.bytes.length(),
            )
          }
      }
    }
    writer.write_u32(session.pending.length(), "pending-count")
    for message in session.pending {
      encode_message(writer, message, snapshot.version)
    }
  }
  writer.write_u32(snapshot.retained.length(), "retained-count")
  for retained in snapshot.retained {
    writer.write_string(retained.topic)
    writer.write_bytes(retained.payload)
    if retained.qos < 0 ||
      retained.qos > (if snapshot.version == 3 { 2 } else { 1 }) {
      raise InvalidValue(field="retained-qos", offset=writer.bytes.length())
    }
    writer.write_u8(retained.qos, "retained-qos")
  }
  writer.finish()
}

///|
pub fn encode_snapshot(
  snapshot : @router.BrokerSnapshotV3,
  max_snapshot_bytes? : Int = 67108864,
) -> Result[Bytes, PersistenceError] {
  try {
    if max_snapshot_bytes < disk_header_bytes {
      raise InvalidConfiguration("max_snapshot_bytes must be at least 24")
    }
    let payload = encode_payload(
      snapshot,
      max_snapshot_bytes - disk_header_bytes,
    )
    if payload.length() > max_snapshot_bytes - disk_header_bytes {
      raise SnapshotTooLarge(
        actual=(disk_header_bytes + payload.length()).to_int64(),
        limit=max_snapshot_bytes.to_int64(),
      )
    }
    let writer = BinaryWriter::new(max_bytes=max_snapshot_bytes)
    writer.write_raw(disk_magic)
    writer.write_u16(snapshot.version, "envelope-version")
    writer.write_u16(0, "flags")
    writer.write_u64_length(payload.length())
    writer.write_u32_bits(crc32(payload))
    writer.write_raw(payload)
    Ok(writer.finish())
  } catch {
    error => Err(error)
  }
}

///|
fn checked_count(
  reader : BinaryReader,
  resource : String,
  limit : Int,
) -> Int raise PersistenceError {
  let count = reader.read_u32(resource)
  if count > limit {
    raise LimitExceeded(
      resource~,
      actual=count.to_int64(),
      limit=limit.to_int64(),
    )
  }
  count
}

///|
fn decode_message(
  reader : BinaryReader,
  max_payload : Int,
  version : Int,
) -> @router.SnapshotMessageV3 raise PersistenceError {
  let topic = reader.read_string()
  let payload = reader.read_bytes(max_payload)
  let retain_offset = reader.position()
  let retain = match reader.read_u8() {
    0 => false
    1 => true
    _ => raise InvalidValue(field="message-retain", offset=retain_offset)
  }
  let qos = if version == 3 {
    let offset = reader.position()
    let qos = reader.read_u8()
    if qos < 1 || qos > 2 {
      raise InvalidValue(field="message-qos", offset~)
    }
    qos
  } else {
    1
  }
  { topic, payload, retain, qos }
}

///|
fn decode_payload(
  payload : Bytes,
  limits : SnapshotDecodeLimits,
  envelope_version : Int,
  workspace : DecodeWorkspace?,
) -> @router.BrokerSnapshotV3 raise PersistenceError {
  let reader = BinaryReader::new(payload)
  let version = reader.read_u32("snapshot-model-version")
  if version != envelope_version ||
    (version != 1 && version != 2 && version != 3) {
    raise InvalidValue(field="snapshot-model-version", offset=0)
  }
  let broker = limits.broker_config()
  let budget = DecodeBudget::new(broker.resources(), workspace)
  let session_count = checked_count(reader, "sessions", broker.max_sessions())
  let sessions : Array[@router.SnapshotSessionV3] = []
  let mut subscription_total = 0
  let mut inflight_total = 0
  let mut pending_total = 0
  let mut inbound_total = 0
  for _ in 0..<session_count {
    budget.new_session()
    let id_bytes = reader.peek_string_bytes()
    let owner_bytes = if version >= 2 {
      reader.peek_string_bytes(relative=4 + id_bytes).to_int64()
    } else {
      @budget.utf8_bytes("legacy-anonymous")
    }
    budget.charge("identity", id_bytes.to_int64() + owner_bytes + 256L)
    let client_id = reader.read_string()
    let owner_principal = if version >= 2 {
      reader.read_string()
    } else {
      "legacy-anonymous"
    }
    let detached_at_ms = if version >= 2 {
      let offset = reader.position()
      let encoded = reader.read_string()
      let value = @string.parse_int64(encoded) catch {
        _ => raise InvalidValue(field="detached-at-ms", offset~)
      }
      if value < 0L {
        raise InvalidValue(field="detached-at-ms", offset~)
      }
      value
    } else {
      0L
    }
    let next_offset = reader.position()
    let next_packet_id = reader.read_u16()
    if next_packet_id == 0 {
      raise InvalidValue(field="next-packet-id", offset=next_offset)
    }
    let subscription_count = checked_count(
      reader,
      "subscriptions-per-session",
      broker.max_subscriptions_per_session(),
    )
    if subscription_count >
      broker.max_subscriptions_total() - subscription_total {
      raise LimitExceeded(
        resource="subscriptions-total",
        actual=(subscription_total + subscription_count).to_int64(),
        limit=broker.max_subscriptions_total().to_int64(),
      )
    }
    subscription_total = subscription_total + subscription_count
    let subscriptions : Array[@router.SnapshotSubscriptionV3] = []
    for _ in 0..<subscription_count {
      budget.charge("subscription", reader.peek_string_bytes().to_int64() + 64L)
      let filter = reader.read_string()
      let qos_offset = reader.position()
      let qos = reader.read_u8()
      if qos > (if version == 3 { 2 } else { 1 }) {
        raise InvalidValue(field="subscription-qos", offset=qos_offset)
      }
      subscriptions.push({ filter, qos })
    }
    let inbound_qos2 : Array[Int] = []
    if version == 3 {
      let count = checked_count(
        reader,
        "inbound-qos2-per-session",
        broker.max_inbound_qos2_per_session(),
      )
      if count > broker.max_inbound_qos2_total() - inbound_total {
        raise LimitExceeded(
          resource="inbound-qos2-total",
          actual=(inbound_total + count).to_int64(),
          limit=broker.max_inbound_qos2_total().to_int64(),
        )
      }
      inbound_total += count
      budget.charge("inbound", count.to_int64() * 64L)
      for _ in 0..<count {
        let offset = reader.position()
        let id = reader.read_u16()
        if id == 0 || inbound_qos2.contains(id) {
          raise InvalidValue(field="inbound-packet-id", offset~)
        }
        inbound_qos2.push(id)
      }
    }
    let inflight_count = checked_count(
      reader,
      "inflight-per-session",
      broker.max_inflight_per_session(),
    )
    if inflight_count > broker.max_inflight_total() - inflight_total {
      raise LimitExceeded(
        resource="inflight-total",
        actual=(inflight_total + inflight_count).to_int64(),
        limit=broker.max_inflight_total().to_int64(),
      )
    }
    inflight_total = inflight_total + inflight_count
    let inflight : Array[@router.SnapshotInflightV3] = []
    for _ in 0..<inflight_count {
      let packet_offset = reader.position()
      let packet_id = reader.read_u16()
      if packet_id == 0 {
        raise InvalidValue(field="packet-id", offset=packet_offset)
      }
      let offset = reader.position()
      let phase = if version == 3 { reader.read_u8() } else { 1 }
      if phase < 1 || phase > 3 {
        raise InvalidValue(field="outbound-phase", offset~)
      }
      let message = if phase == 3 {
        budget.charge("inflight", 64L)
        None
      } else {
        budget.charge(
          "inflight",
          reader.peek_message_cost(limits.max_message_payload_bytes()),
        )
        let message = decode_message(
          reader,
          limits.max_message_payload_bytes(),
          version,
        )
        if message.qos != phase {
          raise InvalidValue(field="phase-message", offset~)
        }
        Some(message)
      }
      inflight.push({ packet_id, phase, message })
    }
    let pending_count = checked_count(
      reader,
      "pending-per-session",
      broker.max_pending_qos1_per_session(),
    )
    if pending_count > broker.max_pending_qos1_total() - pending_total {
      raise LimitExceeded(
        resource="pending-total",
        actual=(pending_total + pending_count).to_int64(),
        limit=broker.max_pending_qos1_total().to_int64(),
      )
    }
    pending_total = pending_total + pending_count
    let pending : Array[@router.SnapshotMessageV3] = []
    for _ in 0..<pending_count {
      budget.charge(
        "pending",
        reader.peek_message_cost(limits.max_message_payload_bytes()),
      )
      pending.push(
        decode_message(reader, limits.max_message_payload_bytes(), version),
      )
    }
    sessions.push({
      client_id,
      owner_principal,
      detached_at_ms,
      next_packet_id,
      subscriptions,
      inbound_qos2,
      inflight,
      pending,
    })
  }
  let retained_count = checked_count(
    reader,
    "retained",
    broker.max_retained_messages(),
  )
  let retained : Array[@router.SnapshotRetainedV3] = []
  for _ in 0..<retained_count {
    budget.charge(
      "retained",
      reader.peek_message_cost(limits.max_message_payload_bytes()),
    )
    let topic = reader.read_string()
    let bytes = reader.read_bytes(limits.max_message_payload_bytes())
    let qos_offset = reader.position()
    let qos = reader.read_u8()
    if qos > (if version == 3 { 2 } else { 1 }) {
      raise InvalidValue(field="retained-qos", offset=qos_offset)
    }
    retained.push({ topic, payload: bytes, qos })
  }
  if reader.remaining() != 0 {
    raise TrailingData(offset=reader.position())
  }
  { version, sessions, retained }
}

///|
pub fn decode_snapshot(
  data : Bytes,
  limits : SnapshotDecodeLimits,
  workspace? : DecodeWorkspace,
) -> Result[@router.BrokerSnapshotV3, PersistenceError] {
  try {
    if data.length() > limits.max_snapshot_bytes() {
      raise SnapshotTooLarge(
        actual=data.length().to_int64(),
        limit=limits.max_snapshot_bytes().to_int64(),
      )
    }
    let reader = BinaryReader::new(data)
    let magic = reader.read_raw(8)
    if magic != disk_magic {
      raise InvalidMagic
    }
    let envelope_version = reader.read_u16()
    if envelope_version != 1 && envelope_version != 2 && envelope_version != 3 {
      raise UnsupportedEnvelopeVersion(envelope_version)
    }
    let flags = reader.read_u16()
    if flags != 0 {
      raise UnknownFlags(flags)
    }
    let declared_length = reader.read_u64_length()
    let expected_crc = reader.read_u32_bits()
    if declared_length != reader.remaining() {
      raise LengthMismatch(
        declared=declared_length.to_int64(),
        actual=reader.remaining().to_int64(),
      )
    }
    let payload = reader.read_raw(declared_length)
    let actual_crc = crc32(payload)
    if actual_crc != expected_crc {
      raise ChecksumMismatch(expected=expected_crc, actual=actual_crc)
    }
    Ok(decode_payload(payload, limits, envelope_version, workspace))
  } catch {
    error => Err(error)
  }
}
