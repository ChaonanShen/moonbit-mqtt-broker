///|
let disk_magic : Bytes = b"MBMQTT01"

///|
let disk_header_bytes : Int = 24

///|
fn encode_message(
  writer : BinaryWriter,
  message : @router.SnapshotMessageV1,
) -> Unit raise PersistenceError {
  writer.write_string(message.topic)
  writer.write_bytes(message.payload)
  writer.write_u8(if message.retain { 1 } else { 0 }, "message-retain")
}

///|
fn encode_payload(
  snapshot : @router.BrokerSnapshotV1,
) -> Bytes raise PersistenceError {
  let writer = BinaryWriter::new()
  writer.write_u32(snapshot.version, "snapshot-model-version")
  if snapshot.version != 1 && snapshot.version != 2 {
    raise InvalidValue(field="snapshot-model-version", offset=0)
  }
  writer.write_u32(snapshot.sessions.length(), "session-count")
  for session in snapshot.sessions {
    writer.write_string(session.client_id)
    if snapshot.version == 2 {
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
      if subscription.qos < 0 || subscription.qos > 1 {
        raise InvalidValue(
          field="subscription-qos",
          offset=writer.bytes.length(),
        )
      }
      writer.write_u8(subscription.qos, "subscription-qos")
    }
    writer.write_u32(session.inflight.length(), "inflight-count")
    for item in session.inflight {
      if item.packet_id < 1 || item.packet_id > 65535 {
        raise InvalidValue(field="packet-id", offset=writer.bytes.length())
      }
      writer.write_u16(item.packet_id, "packet-id")
      encode_message(writer, item.message)
    }
    writer.write_u32(session.pending.length(), "pending-count")
    for message in session.pending {
      encode_message(writer, message)
    }
  }
  writer.write_u32(snapshot.retained.length(), "retained-count")
  for retained in snapshot.retained {
    writer.write_string(retained.topic)
    writer.write_bytes(retained.payload)
    if retained.qos < 0 || retained.qos > 1 {
      raise InvalidValue(field="retained-qos", offset=writer.bytes.length())
    }
    writer.write_u8(retained.qos, "retained-qos")
  }
  writer.finish()
}

///|
pub fn encode_snapshot(
  snapshot : @router.BrokerSnapshotV1,
  max_snapshot_bytes? : Int = 67108864,
) -> Result[Bytes, PersistenceError] {
  try {
    if max_snapshot_bytes < disk_header_bytes {
      raise InvalidConfiguration("max_snapshot_bytes must be at least 24")
    }
    let payload = encode_payload(snapshot)
    if payload.length() > max_snapshot_bytes - disk_header_bytes {
      raise SnapshotTooLarge(
        actual=(disk_header_bytes + payload.length()).to_int64(),
        limit=max_snapshot_bytes.to_int64(),
      )
    }
    let writer = BinaryWriter::new()
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
) -> @router.SnapshotMessageV1 raise PersistenceError {
  let topic = reader.read_string()
  let payload = reader.read_bytes(max_payload)
  let retain_offset = reader.position()
  let retain = match reader.read_u8() {
    0 => false
    1 => true
    _ => raise InvalidValue(field="message-retain", offset=retain_offset)
  }
  { topic, payload, retain }
}

///|
fn decode_payload(
  payload : Bytes,
  limits : SnapshotDecodeLimits,
  envelope_version : Int,
) -> @router.BrokerSnapshotV1 raise PersistenceError {
  let reader = BinaryReader::new(payload)
  let version = reader.read_u32("snapshot-model-version")
  if version != envelope_version || (version != 1 && version != 2) {
    raise InvalidValue(field="snapshot-model-version", offset=0)
  }
  let broker = limits.broker_config()
  let session_count = checked_count(reader, "sessions", broker.max_sessions())
  let sessions : Array[@router.SnapshotSessionV1] = []
  let mut subscription_total = 0
  let mut inflight_total = 0
  let mut pending_total = 0
  for _ in 0..<session_count {
    let client_id = reader.read_string()
    let owner_principal = if version == 2 {
      reader.read_string()
    } else {
      "legacy-anonymous"
    }
    let detached_at_ms = if version == 2 {
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
    let subscriptions : Array[@router.SnapshotSubscriptionV1] = []
    for _ in 0..<subscription_count {
      let filter = reader.read_string()
      let qos_offset = reader.position()
      let qos = reader.read_u8()
      if qos > 1 {
        raise InvalidValue(field="subscription-qos", offset=qos_offset)
      }
      subscriptions.push({ filter, qos })
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
    let inflight : Array[@router.SnapshotInflightV1] = []
    for _ in 0..<inflight_count {
      let packet_offset = reader.position()
      let packet_id = reader.read_u16()
      if packet_id == 0 {
        raise InvalidValue(field="packet-id", offset=packet_offset)
      }
      inflight.push({
        packet_id,
        message: decode_message(reader, limits.max_message_payload_bytes()),
      })
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
    let pending : Array[@router.SnapshotMessageV1] = []
    for _ in 0..<pending_count {
      pending.push(decode_message(reader, limits.max_message_payload_bytes()))
    }
    sessions.push({
      client_id,
      owner_principal,
      detached_at_ms,
      next_packet_id,
      subscriptions,
      inflight,
      pending,
    })
  }
  let retained_count = checked_count(
    reader,
    "retained",
    broker.max_retained_messages(),
  )
  let retained : Array[@router.SnapshotRetainedV1] = []
  for _ in 0..<retained_count {
    let topic = reader.read_string()
    let bytes = reader.read_bytes(limits.max_message_payload_bytes())
    let qos_offset = reader.position()
    let qos = reader.read_u8()
    if qos > 1 {
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
) -> Result[@router.BrokerSnapshotV1, PersistenceError] {
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
    if envelope_version != 1 && envelope_version != 2 {
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
    Ok(decode_payload(payload, limits, envelope_version))
  } catch {
    error => Err(error)
  }
}
