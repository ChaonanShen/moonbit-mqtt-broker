///|
fn v5_write_bool(
  writer : BinaryWriter,
  value : Bool,
) -> Unit raise PersistenceError {
  writer.write_u8(if value { 1 } else { 0 }, "boolean")
}

///|
fn v5_read_bool(reader : BinaryReader) -> Bool raise PersistenceError {
  let offset = reader.position()
  match reader.read_u8() {
    0 => false
    1 => true
    _ => raise InvalidValue(field="boolean", offset~)
  }
}

///|
fn v5_write_optional_string(
  writer : BinaryWriter,
  value : String?,
) -> Unit raise PersistenceError {
  match value {
    None => writer.write_u8(0, "optional-string")
    Some(text) => {
      writer.write_u8(1, "optional-string")
      writer.write_string(text)
    }
  }
}

///|
fn v5_read_optional_string(
  reader : BinaryReader,
) -> String? raise PersistenceError {
  if v5_read_bool(reader) {
    Some(reader.read_string())
  } else {
    None
  }
}

///|
fn v5_write_optional_bytes(
  writer : BinaryWriter,
  value : Bytes?,
) -> Unit raise PersistenceError {
  match value {
    None => writer.write_u8(0, "optional-bytes")
    Some(bytes) => {
      writer.write_u8(1, "optional-bytes")
      writer.write_bytes(bytes)
    }
  }
}

///|
fn v5_read_optional_bytes(
  reader : BinaryReader,
  max_bytes : Int,
) -> Bytes? raise PersistenceError {
  if v5_read_bool(reader) {
    Some(reader.read_bytes(max_bytes))
  } else {
    None
  }
}

///|
fn v5_write_optional_u32(
  writer : BinaryWriter,
  value : UInt?,
) -> Unit raise PersistenceError {
  match value {
    None => writer.write_u8(0, "optional-u32")
    Some(number) => {
      writer.write_u8(1, "optional-u32")
      writer.write_u32_bits(number)
    }
  }
}

///|
fn v5_read_optional_u32(reader : BinaryReader) -> UInt? raise PersistenceError {
  if v5_read_bool(reader) {
    Some(reader.read_u32_bits())
  } else {
    None
  }
}

///|
fn v5_write_optional_i64(
  writer : BinaryWriter,
  value : Int64?,
) -> Unit raise PersistenceError {
  match value {
    None => writer.write_u8(0, "optional-i64")
    Some(number) => {
      writer.write_u8(1, "optional-i64")
      writer.write_positive_i64(number, "optional-i64")
    }
  }
}

///|
fn v5_read_optional_i64(reader : BinaryReader) -> Int64? raise PersistenceError {
  if v5_read_bool(reader) {
    Some(reader.read_positive_i64("optional-i64"))
  } else {
    None
  }
}

///|
fn v5_write_clock(
  writer : BinaryWriter,
  value : @router.SnapshotClockV5,
) -> Unit raise PersistenceError {
  if value.sample_wall_ms < 0L ||
    value.remaining_ms < 0L ||
    value.deadline_wall_ms < 0L ||
    value.deadline_wall_ms - value.sample_wall_ms != value.remaining_ms {
    raise InvalidValue(field="clock", offset=writer.bytes.length())
  }
  writer.write_positive_i64(value.sample_wall_ms, "clock-sample")
  writer.write_positive_i64(value.remaining_ms, "clock-remaining")
  writer.write_positive_i64(value.deadline_wall_ms, "clock-deadline")
}

///|
fn v5_read_clock(
  reader : BinaryReader,
) -> @router.SnapshotClockV5 raise PersistenceError {
  let sample_wall_ms = reader.read_positive_i64("clock-sample")
  let remaining_ms = reader.read_positive_i64("clock-remaining")
  let deadline_wall_ms = reader.read_positive_i64("clock-deadline")
  if deadline_wall_ms < sample_wall_ms ||
    deadline_wall_ms - sample_wall_ms != remaining_ms {
    raise InvalidValue(field="clock", offset=reader.position())
  }
  { sample_wall_ms, remaining_ms, deadline_wall_ms }
}

///|
fn v5_write_optional_clock(
  writer : BinaryWriter,
  value : @router.SnapshotClockV5?,
) -> Unit raise PersistenceError {
  match value {
    None => writer.write_u8(0, "optional-clock")
    Some(clock) => {
      writer.write_u8(1, "optional-clock")
      v5_write_clock(writer, clock)
    }
  }
}

///|
fn v5_read_optional_clock(
  reader : BinaryReader,
) -> @router.SnapshotClockV5? raise PersistenceError {
  if v5_read_bool(reader) {
    Some(v5_read_clock(reader))
  } else {
    None
  }
}

///|
fn v5_write_retention(
  writer : BinaryWriter,
  value : @session.Retention,
) -> Unit raise PersistenceError {
  match value {
    DropOnClose => writer.write_u8(0, "retention")
    LegacyBrokerPolicy => writer.write_u8(1, "retention")
    FiniteV5(seconds) => {
      if seconds == 0U || seconds == 0xffffffffU {
        raise InvalidValue(field="retention", offset=writer.bytes.length())
      }
      writer.write_u8(2, "retention")
      writer.write_u32_bits(seconds)
    }
    InfiniteV5 => writer.write_u8(3, "retention")
  }
}

///|
fn v5_read_retention(
  reader : BinaryReader,
) -> @session.Retention raise PersistenceError {
  match reader.read_u8() {
    0 => DropOnClose
    1 => LegacyBrokerPolicy
    2 => {
      let seconds = reader.read_u32_bits()
      if seconds == 0U || seconds == 0xffffffffU {
        raise InvalidValue(field="retention", offset=reader.position())
      }
      FiniteV5(seconds)
    }
    3 => InfiniteV5
    _ => raise InvalidValue(field="retention", offset=reader.position())
  }
}

///|
fn v5_write_properties(
  writer : BinaryWriter,
  value : @router.SnapshotApplicationPropertiesV5,
) -> Unit raise PersistenceError {
  match value.payload_format {
    None => writer.write_u8(0, "payload-format-present")
    Some(format) => {
      if format != 0 && format != 1 {
        raise InvalidValue(field="payload-format", offset=writer.bytes.length())
      }
      writer.write_u8(1, "payload-format-present")
      writer.write_u8(format, "payload-format")
    }
  }
  v5_write_optional_string(writer, value.content_type)
  v5_write_optional_string(writer, value.response_topic)
  v5_write_optional_bytes(writer, value.correlation_data)
  if value.user_properties.length() > 1024 {
    raise LimitExceeded(
      resource="user-properties",
      actual=value.user_properties.length().to_int64(),
      limit=1024L,
    )
  }
  writer.write_u32(value.user_properties.length(), "user-property-count")
  for entry in value.user_properties {
    let (key, text) = entry
    writer.write_string(key)
    writer.write_string(text)
  }
}

///|
fn v5_read_properties(
  reader : BinaryReader,
  max_payload : Int,
) -> @router.SnapshotApplicationPropertiesV5 raise PersistenceError {
  let payload_format = if v5_read_bool(reader) {
    let value = reader.read_u8()
    if value > 1 {
      raise InvalidValue(field="payload-format", offset=reader.position())
    }
    Some(value)
  } else {
    None
  }
  let content_type = v5_read_optional_string(reader)
  let response_topic = v5_read_optional_string(reader)
  let correlation_data = v5_read_optional_bytes(reader, max_payload)
  let count = checked_count(reader, "user-properties", 1024)
  let user_properties : Array[(String, String)] = []
  for _ in 0..<count {
    user_properties.push((reader.read_string(), reader.read_string()))
  }
  {
    payload_format,
    content_type,
    response_topic,
    correlation_data,
    user_properties,
  }
}

///|
fn v5_write_message(
  writer : BinaryWriter,
  value : @router.SnapshotMessageV5,
) -> Unit raise PersistenceError {
  writer.write_string(value.topic)
  writer.write_bytes(value.payload)
  if value.qos < 0 || value.qos > 2 {
    raise InvalidValue(field="message-qos", offset=writer.bytes.length())
  }
  writer.write_u8(value.qos, "message-qos")
  v5_write_bool(writer, value.retain)
  v5_write_optional_string(writer, value.publisher_client_id)
  v5_write_properties(writer, value.properties)
  v5_write_optional_clock(writer, value.expiry_clock)
}

///|
fn v5_read_message(
  reader : BinaryReader,
  max_payload : Int,
) -> @router.SnapshotMessageV5 raise PersistenceError {
  let topic = reader.read_string()
  let payload = reader.read_bytes(max_payload)
  let qos = reader.read_u8()
  if qos > 2 {
    raise InvalidValue(field="message-qos", offset=reader.position())
  }
  let retain = v5_read_bool(reader)
  let publisher_client_id = v5_read_optional_string(reader)
  let properties = v5_read_properties(reader, max_payload)
  let expiry_clock = v5_read_optional_clock(reader)
  { topic, payload, qos, retain, publisher_client_id, properties, expiry_clock }
}

///|
fn v5_write_shared_origin(
  writer : BinaryWriter,
  value : @router.SnapshotSharedOriginV5?,
) -> Unit raise PersistenceError {
  match value {
    None => writer.write_u8(0, "shared-origin")
    Some(origin) => {
      writer.write_u8(1, "shared-origin")
      writer.write_positive_i64(origin.group_id, "group-id")
      writer.write_positive_i64(origin.group_incarnation, "group-incarnation")
    }
  }
}

///|
fn v5_read_shared_origin(
  reader : BinaryReader,
) -> @router.SnapshotSharedOriginV5? raise PersistenceError {
  if v5_read_bool(reader) {
    let group_id = reader.read_positive_i64("group-id")
    let group_incarnation = reader.read_positive_i64("group-incarnation")
    if group_id == 0L || group_incarnation == 0L {
      raise InvalidValue(field="shared-origin", offset=reader.position())
    }
    Some({ group_id, group_incarnation })
  } else {
    None
  }
}

///|
fn v5_write_subscription(
  writer : BinaryWriter,
  value : @router.SnapshotSubscriptionV5,
) -> Unit raise PersistenceError {
  if value.identity < 1L ||
    value.kind < 0 ||
    value.kind > 2 ||
    value.qos < 0 ||
    value.qos > 2 ||
    value.retain_handling < 0 ||
    value.retain_handling > 2 {
    raise InvalidValue(field="subscription", offset=writer.bytes.length())
  }
  writer.write_positive_i64(value.identity, "subscription-identity")
  writer.write_u8(value.kind, "subscription-kind")
  writer.write_string(value.wire_filter)
  let shared = match
    (value.group_id, value.group_incarnation, value.inner_filter) {
    (None, None, None) => false
    (Some(_), Some(_), Some(_)) => true
    _ =>
      raise InvalidValue(
        field="subscription-group",
        offset=writer.bytes.length(),
      )
  }
  v5_write_bool(writer, shared)
  if shared {
    writer.write_positive_i64(value.group_id.unwrap(), "group-id")
    writer.write_positive_i64(
      value.group_incarnation.unwrap(),
      "group-incarnation",
    )
    writer.write_string(value.inner_filter.unwrap())
  }
  writer.write_u8(value.qos, "subscription-qos")
  v5_write_bool(writer, value.no_local)
  v5_write_bool(writer, value.retain_as_published)
  writer.write_u8(value.retain_handling, "retain-handling")
  v5_write_optional_u32(writer, value.subscription_identifier)
}

///|
fn v5_read_subscription(
  reader : BinaryReader,
) -> @router.SnapshotSubscriptionV5 raise PersistenceError {
  let identity = reader.read_positive_i64("subscription-identity")
  let kind = reader.read_u8()
  let wire_filter = reader.read_string()
  let shared = v5_read_bool(reader)
  let (group_id, group_incarnation, inner_filter) = if shared {
    (
      Some(reader.read_positive_i64("group-id")),
      Some(reader.read_positive_i64("group-incarnation")),
      Some(reader.read_string()),
    )
  } else {
    (None, None, None)
  }
  let qos = reader.read_u8()
  let no_local = v5_read_bool(reader)
  let retain_as_published = v5_read_bool(reader)
  let retain_handling = reader.read_u8()
  let subscription_identifier = v5_read_optional_u32(reader)
  if identity < 1L ||
    kind > 2 ||
    qos > 2 ||
    retain_handling > 2 ||
    (kind == 1) != shared ||
    (subscription_identifier is Some(id) && (id == 0U || id > 268435455U)) {
    raise InvalidValue(field="subscription", offset=reader.position())
  }
  {
    identity,
    kind,
    wire_filter,
    group_id,
    group_incarnation,
    inner_filter,
    qos,
    no_local,
    retain_as_published,
    retain_handling,
    subscription_identifier,
  }
}

///|
fn v5_write_group(
  writer : BinaryWriter,
  value : @router.SnapshotGroupV5,
) -> Unit raise PersistenceError {
  if value.id < 1L ||
    value.incarnation < 1L ||
    value.revision < 1L ||
    (value.state != 0 && value.state != 1) {
    raise InvalidValue(field="group", offset=writer.bytes.length())
  }
  writer.write_positive_i64(value.id, "group-id")
  writer.write_positive_i64(value.incarnation, "group-incarnation")
  writer.write_string(value.name)
  writer.write_string(value.inner_filter)
  writer.write_u8(value.state, "group-state")
  writer.write_positive_i64(value.revision, "group-revision")
}

///|
fn v5_read_group(
  reader : BinaryReader,
) -> @router.SnapshotGroupV5 raise PersistenceError {
  let id = reader.read_positive_i64("group-id")
  let incarnation = reader.read_positive_i64("group-incarnation")
  let name = reader.read_string()
  let inner_filter = reader.read_string()
  let state = reader.read_u8()
  let revision = reader.read_positive_i64("group-revision")
  if id < 1L ||
    incarnation < 1L ||
    revision < 1L ||
    state > 1 ||
    name == "" ||
    inner_filter == "" {
    raise InvalidValue(field="group", offset=reader.position())
  }
  { id, incarnation, name, inner_filter, state, revision }
}

///|
fn v5_write_pending(
  writer : BinaryWriter,
  value : @router.SnapshotPendingV5,
) -> Unit raise PersistenceError {
  if value.delivery_id < 1L || value.message.qos == 0 {
    raise InvalidValue(field="pending", offset=writer.bytes.length())
  }
  writer.write_positive_i64(value.delivery_id, "delivery-id")
  v5_write_message(writer, value.message)
  v5_write_shared_origin(writer, value.shared_origin)
  writer.write_u32(
    value.subscription_identifiers.length(),
    "subscription-id-count",
  )
  for id in value.subscription_identifiers {
    writer.write_u32_bits(id)
  }
}

///|
fn v5_read_pending(
  reader : BinaryReader,
  max_payload : Int,
) -> @router.SnapshotPendingV5 raise PersistenceError {
  let delivery_id = reader.read_positive_i64("delivery-id")
  let message = v5_read_message(reader, max_payload)
  let shared_origin = v5_read_shared_origin(reader)
  let count = checked_count(reader, "subscription-id-count", 1024)
  let subscription_identifiers : Array[UInt] = []
  for _ in 0..<count {
    subscription_identifiers.push(reader.read_u32_bits())
  }
  if delivery_id < 1L ||
    message.qos == 0 ||
    subscription_identifiers.any(id => id == 0U || id > 268435455U) {
    raise InvalidValue(field="pending", offset=reader.position())
  }
  { delivery_id, message, shared_origin, subscription_identifiers }
}

///|
fn v5_write_inflight(
  writer : BinaryWriter,
  value : @router.SnapshotInflightV5,
) -> Unit raise PersistenceError {
  if value.packet_id < 1 ||
    value.packet_id > 65535 ||
    value.delivery_id < 1L ||
    value.phase < 1 ||
    value.phase > 3 {
    raise InvalidValue(field="inflight", offset=writer.bytes.length())
  }
  writer.write_u16(value.packet_id, "packet-id")
  writer.write_positive_i64(value.delivery_id, "delivery-id")
  writer.write_u8(value.phase, "outbound-phase")
  v5_write_bool(writer, value.started)
  match value.message {
    None => writer.write_u8(0, "inflight-message")
    Some(message) => {
      writer.write_u8(1, "inflight-message")
      v5_write_message(writer, message)
    }
  }
  v5_write_shared_origin(writer, value.shared_origin)
  writer.write_u32(
    value.subscription_identifiers.length(),
    "subscription-id-count",
  )
  for id in value.subscription_identifiers {
    writer.write_u32_bits(id)
  }
}

///|
fn v5_read_inflight(
  reader : BinaryReader,
  max_payload : Int,
) -> @router.SnapshotInflightV5 raise PersistenceError {
  let packet_id = reader.read_u16()
  let delivery_id = reader.read_positive_i64("delivery-id")
  let phase = reader.read_u8()
  let started = v5_read_bool(reader)
  let message = if v5_read_bool(reader) {
    Some(v5_read_message(reader, max_payload))
  } else {
    None
  }
  let shared_origin = v5_read_shared_origin(reader)
  let count = checked_count(reader, "subscription-id-count", 1024)
  let subscription_identifiers : Array[UInt] = []
  for _ in 0..<count {
    subscription_identifiers.push(reader.read_u32_bits())
  }
  if packet_id == 0 ||
    delivery_id < 1L ||
    phase < 1 ||
    phase > 3 ||
    (phase == 3) != (message is None) ||
    (message is Some(value) && value.qos != phase) ||
    subscription_identifiers.any(id => id == 0U || id > 268435455U) {
    raise InvalidValue(field="inflight", offset=reader.position())
  }
  {
    packet_id,
    delivery_id,
    phase,
    started,
    message,
    shared_origin,
    subscription_identifiers,
  }
}

///|
fn v5_write_session(
  writer : BinaryWriter,
  value : @router.SnapshotSessionV5,
) -> Unit raise PersistenceError {
  if value.incarnation < 1L ||
    value.lifecycle_version < 1L ||
    value.state_revision < 1L ||
    (value.last_protocol != 4 && value.last_protocol != 5) ||
    value.next_packet_id < 1 ||
    value.next_packet_id > 65535 {
    raise InvalidValue(field="session", offset=writer.bytes.length())
  }
  writer.write_string(value.client_id)
  writer.write_string(value.owner_principal)
  writer.write_positive_i64(value.incarnation, "session-incarnation")
  writer.write_positive_i64(value.lifecycle_version, "lifecycle-version")
  writer.write_positive_i64(value.state_revision, "state-revision")
  writer.write_u8(value.last_protocol, "last-protocol")
  v5_write_retention(writer, value.retention)
  v5_write_bool(writer, value.attached_at_capture)
  v5_write_optional_i64(writer, value.detached_at_wall_ms)
  v5_write_optional_clock(writer, value.session_expiry_clock)
  writer.write_u16(value.next_packet_id, "next-packet-id")
  writer.write_u32(value.subscriptions.length(), "subscription-count")
  for subscription in value.subscriptions {
    v5_write_subscription(writer, subscription)
  }
  writer.write_u32(value.inbound_qos2.length(), "inbound-qos2-count")
  for item in value.inbound_qos2 {
    writer.write_u16(item.packet_id, "inbound-packet-id")
    writer.write_u8(item.success_reason, "inbound-success-reason")
  }
  writer.write_u32(value.inflight.length(), "inflight-count")
  for item in value.inflight {
    v5_write_inflight(writer, item)
  }
  writer.write_u32(value.pending.length(), "pending-count")
  for item in value.pending {
    v5_write_pending(writer, item)
  }
}

///|
fn v5_read_session(
  reader : BinaryReader,
  limits : SnapshotDecodeLimits,
) -> @router.SnapshotSessionV5 raise PersistenceError {
  let client_id = reader.read_string()
  let owner_principal = reader.read_string()
  let incarnation = reader.read_positive_i64("session-incarnation")
  let lifecycle_version = reader.read_positive_i64("lifecycle-version")
  let state_revision = reader.read_positive_i64("state-revision")
  let last_protocol = reader.read_u8()
  let retention = v5_read_retention(reader)
  let attached_at_capture = v5_read_bool(reader)
  let detached_at_wall_ms = v5_read_optional_i64(reader)
  let session_expiry_clock = v5_read_optional_clock(reader)
  let next_packet_id = reader.read_u16()
  let broker = limits.broker_config()
  let sub_count = checked_count(
    reader,
    "subscription-count",
    broker.max_subscriptions_per_session(),
  )
  let subscriptions : Array[@router.SnapshotSubscriptionV5] = []
  for _ in 0..<sub_count {
    subscriptions.push(v5_read_subscription(reader))
  }
  let inbound_count = checked_count(
    reader,
    "inbound-qos2-count",
    broker.max_inbound_qos2_per_session(),
  )
  let inbound_qos2 : Array[@router.SnapshotInboundQoS2V5] = []
  for _ in 0..<inbound_count {
    let packet_id = reader.read_u16()
    let success_reason = reader.read_u8()
    if packet_id == 0 || success_reason != 0 {
      raise InvalidValue(field="inbound-qos2", offset=reader.position())
    }
    inbound_qos2.push({ packet_id, success_reason })
  }
  let inflight_count = checked_count(
    reader,
    "inflight-count",
    broker.max_inflight_per_session(),
  )
  let inflight : Array[@router.SnapshotInflightV5] = []
  for _ in 0..<inflight_count {
    inflight.push(v5_read_inflight(reader, limits.max_message_payload_bytes()))
  }
  let pending_count = checked_count(
    reader,
    "pending-count",
    broker.max_pending_qos1_per_session(),
  )
  let pending : Array[@router.SnapshotPendingV5] = []
  for _ in 0..<pending_count {
    pending.push(v5_read_pending(reader, limits.max_message_payload_bytes()))
  }
  if client_id == "" ||
    incarnation < 1L ||
    lifecycle_version < 1L ||
    state_revision < 1L ||
    (last_protocol != 4 && last_protocol != 5) ||
    next_packet_id == 0 ||
    (
      attached_at_capture &&
      (detached_at_wall_ms is Some(_) || session_expiry_clock is Some(_))
    ) ||
    (!attached_at_capture && detached_at_wall_ms is None) {
    raise InvalidValue(field="session", offset=reader.position())
  }
  {
    client_id,
    owner_principal,
    incarnation,
    lifecycle_version,
    state_revision,
    last_protocol,
    retention,
    attached_at_capture,
    detached_at_wall_ms,
    session_expiry_clock,
    next_packet_id,
    subscriptions,
    inbound_qos2,
    inflight,
    pending,
  }
}

///|
fn v5_write_will(
  writer : BinaryWriter,
  value : @router.SnapshotWillV5,
) -> Unit raise PersistenceError {
  if value.id < 1L ||
    value.session_incarnation < 1L ||
    value.policy_sequence < 0L ||
    value.revision < 1L ||
    (value.state != 0 && value.state != 1) ||
    (
      value.state == 0 &&
      (value.trigger_wall_ms is Some(_) || value.due_clock is Some(_))
    ) ||
    (
      value.state == 1 &&
      (value.trigger_wall_ms is None || value.due_clock is None)
    ) {
    raise InvalidValue(field="will", offset=writer.bytes.length())
  }
  writer.write_positive_i64(value.id, "will-id")
  writer.write_string(value.owner_principal)
  writer.write_string(value.client_id)
  writer.write_positive_i64(
    value.session_incarnation,
    "will-session-incarnation",
  )
  writer.write_u8(value.state, "will-state")
  v5_write_message(writer, value.message_template)
  writer.write_u32_bits(value.delay_seconds)
  v5_write_optional_u32(writer, value.will_message_expiry_seconds)
  v5_write_optional_i64(writer, value.trigger_wall_ms)
  v5_write_optional_clock(writer, value.due_clock)
  writer.write_positive_i64(value.policy_sequence, "will-policy-sequence")
  writer.write_positive_i64(value.revision, "will-revision")
}

///|
fn v5_read_will(
  reader : BinaryReader,
  max_payload : Int,
) -> @router.SnapshotWillV5 raise PersistenceError {
  let id = reader.read_positive_i64("will-id")
  let owner_principal = reader.read_string()
  let client_id = reader.read_string()
  let session_incarnation = reader.read_positive_i64("will-session-incarnation")
  let state = reader.read_u8()
  let message_template = v5_read_message(reader, max_payload)
  let delay_seconds = reader.read_u32_bits()
  let will_message_expiry_seconds = v5_read_optional_u32(reader)
  let trigger_wall_ms = v5_read_optional_i64(reader)
  let due_clock = v5_read_optional_clock(reader)
  let policy_sequence = reader.read_positive_i64("will-policy-sequence")
  let revision = reader.read_positive_i64("will-revision")
  if id < 1L ||
    client_id == "" ||
    session_incarnation < 1L ||
    state > 1 ||
    revision < 1L ||
    message_template.expiry_clock is Some(_) ||
    (state == 0 && (trigger_wall_ms is Some(_) || due_clock is Some(_))) ||
    (state == 1 && (trigger_wall_ms is None || due_clock is None)) {
    raise InvalidValue(field="will", offset=reader.position())
  }
  {
    id,
    owner_principal,
    client_id,
    session_incarnation,
    state,
    message_template,
    delay_seconds,
    will_message_expiry_seconds,
    trigger_wall_ms,
    due_clock,
    policy_sequence,
    revision,
  }
}

///|
fn v5_write_payload(
  writer : BinaryWriter,
  snapshot : @router.BrokerSnapshotV5,
) -> Unit raise PersistenceError {
  writer.write_u32(mqtt5_snapshot_model_version, "snapshot-model-version")
  writer.write_positive_i64(snapshot.clock_floor_wall_ms, "clock-floor")
  writer.write_positive_i64(
    snapshot.next_session_incarnation,
    "next-session-incarnation",
  )
  writer.write_positive_i64(
    snapshot.next_subscription_identity,
    "next-subscription-identity",
  )
  writer.write_positive_i64(snapshot.next_delivery_id, "next-delivery-id")
  writer.write_positive_i64(snapshot.next_group_id, "next-group-id")
  writer.write_positive_i64(snapshot.next_will_id, "next-will-id")
  writer.write_positive_i64(
    snapshot.next_retained_revision,
    "next-retained-revision",
  )
  writer.write_u32(snapshot.groups.length(), "group-count")
  for group in snapshot.groups {
    v5_write_group(writer, group)
  }
  writer.write_u32(snapshot.sessions.length(), "session-count")
  for session in snapshot.sessions {
    v5_write_session(writer, session)
  }
  writer.write_u32(snapshot.retained.length(), "retained-count")
  for retained in snapshot.retained {
    writer.write_positive_i64(retained.revision, "retained-revision")
    v5_write_message(writer, retained.message)
  }
  writer.write_u32(snapshot.wills.length(), "will-count")
  for will in snapshot.wills {
    v5_write_will(writer, will)
  }
}

///|
fn v5_read_payload(
  reader : BinaryReader,
  limits : SnapshotDecodeLimits,
) -> @router.BrokerSnapshotV5 raise PersistenceError {
  let version = reader.read_u32("snapshot-model-version")
  if version != mqtt5_snapshot_model_version {
    raise UnsupportedEnvelopeVersion(version)
  }
  let clock_floor_wall_ms = reader.read_positive_i64("clock-floor")
  let next_session_incarnation = reader.read_positive_i64(
    "next-session-incarnation",
  )
  let next_subscription_identity = reader.read_positive_i64(
    "next-subscription-identity",
  )
  let next_delivery_id = reader.read_positive_i64("next-delivery-id")
  let next_group_id = reader.read_positive_i64("next-group-id")
  let next_will_id = reader.read_positive_i64("next-will-id")
  let next_retained_revision = reader.read_positive_i64(
    "next-retained-revision",
  )
  let broker = limits.broker_config()
  let group_count = checked_count(reader, "group-count", 1024)
  let groups : Array[@router.SnapshotGroupV5] = []
  for _ in 0..<group_count {
    groups.push(v5_read_group(reader))
  }
  let session_count = checked_count(
    reader,
    "session-count",
    broker.max_sessions(),
  )
  let sessions : Array[@router.SnapshotSessionV5] = []
  for _ in 0..<session_count {
    sessions.push(v5_read_session(reader, limits))
  }
  let retained_count = checked_count(
    reader,
    "retained-count",
    broker.max_retained_messages(),
  )
  let retained : Array[@router.SnapshotRetainedV5] = []
  for _ in 0..<retained_count {
    retained.push({
      revision: reader.read_positive_i64("retained-revision"),
      message: v5_read_message(reader, limits.max_message_payload_bytes()),
    })
  }
  let will_count = checked_count(
    reader,
    "will-count",
    broker.max_sessions() + 1024,
  )
  let wills : Array[@router.SnapshotWillV5] = []
  for _ in 0..<will_count {
    wills.push(v5_read_will(reader, limits.max_message_payload_bytes()))
  }
  if reader.remaining() != 0 {
    raise TrailingData(offset=reader.position())
  }
  let snapshot : @router.BrokerSnapshotV5 = {
    clock_floor_wall_ms,
    next_session_incarnation,
    next_subscription_identity,
    next_delivery_id,
    next_group_id,
    next_will_id,
    next_retained_revision,
    groups,
    sessions,
    retained,
    wills,
  }
  v5_validate_snapshot(snapshot)
  snapshot
}

///|
fn v5_validate_snapshot(
  snapshot : @router.BrokerSnapshotV5,
) -> Unit raise PersistenceError {
  if snapshot.clock_floor_wall_ms < 0L ||
    snapshot.next_session_incarnation < 1L ||
    snapshot.next_subscription_identity < 1L ||
    snapshot.next_delivery_id < 1L ||
    snapshot.next_group_id < 1L ||
    snapshot.next_will_id < 1L ||
    snapshot.next_retained_revision < 1L {
    raise SnapshotImport("invalid snapshot high-water mark")
  }
  let session_ids : Map[String, Bool] = Map([])
  let subscription_ids : Map[Int64, Bool] = Map([])
  let delivery_ids : Map[Int64, Bool] = Map([])
  let retained_topics : Map[String, Bool] = Map([])
  let will_ids : Map[Int64, Bool] = Map([])
  let group_ids : Map[Int64, Bool] = Map([])
  for group in snapshot.groups {
    if group_ids.contains(group.id) || group.id >= snapshot.next_group_id {
      raise SnapshotImport("duplicate or out-of-range group id")
    }
    group_ids.set(group.id, true)
  }
  for session in snapshot.sessions {
    if session_ids.contains(session.client_id) ||
      session.incarnation >= snapshot.next_session_incarnation {
      raise SnapshotImport("duplicate or out-of-range session")
    }
    session_ids.set(session.client_id, true)
    for subscription in session.subscriptions {
      if subscription_ids.contains(subscription.identity) ||
        subscription.identity >= snapshot.next_subscription_identity {
        raise SnapshotImport("duplicate or out-of-range subscription id")
      }
      subscription_ids.set(subscription.identity, true)
    }
    let packet_ids : Map[Int, Bool] = Map([])
    for item in session.inflight {
      if packet_ids.contains(item.packet_id) ||
        delivery_ids.contains(item.delivery_id) ||
        item.delivery_id >= snapshot.next_delivery_id {
        raise SnapshotImport("duplicate or out-of-range inflight id")
      }
      packet_ids.set(item.packet_id, true)
      delivery_ids.set(item.delivery_id, true)
    }
    for item in session.pending {
      if delivery_ids.contains(item.delivery_id) ||
        item.delivery_id >= snapshot.next_delivery_id {
        raise SnapshotImport("duplicate or out-of-range pending id")
      }
      delivery_ids.set(item.delivery_id, true)
    }
  }
  for item in snapshot.retained {
    if retained_topics.contains(item.message.topic) ||
      item.revision < 1L ||
      item.revision >= snapshot.next_retained_revision {
      raise SnapshotImport("duplicate or out-of-range retained record")
    }
    retained_topics.set(item.message.topic, true)
  }
  for will in snapshot.wills {
    if will_ids.contains(will.id) || will.id >= snapshot.next_will_id {
      raise SnapshotImport("duplicate or out-of-range will id")
    }
    will_ids.set(will.id, true)
  }
}

///|
pub fn encode_snapshot_v5(
  snapshot : @router.BrokerSnapshotV5,
  max_snapshot_bytes? : Int = 67108864,
) -> Result[Bytes, PersistenceError] {
  try {
    v5_validate_snapshot(snapshot)
    if max_snapshot_bytes < 24 {
      raise InvalidConfiguration("snapshot limit below header")
    }
    let body = BinaryWriter::new(max_bytes=max_snapshot_bytes - 24)
    v5_write_payload(body, snapshot)
    let payload = body.finish()
    let writer = BinaryWriter::new(max_bytes=max_snapshot_bytes)
    writer.write_raw(disk_magic)
    writer.write_u16(mqtt5_snapshot_envelope_version, "envelope-version")
    writer.write_u16(0, "envelope-flags")
    writer.write_u64_length(payload.length())
    writer.write_u32_bits(crc32(payload))
    writer.write_raw(payload)
    Ok(writer.finish())
  } catch {
    error => Err(error)
  }
}

///|
pub fn decode_snapshot_v5(
  data : Bytes,
  limits : SnapshotDecodeLimits,
) -> Result[@router.BrokerSnapshotV5, PersistenceError] {
  try {
    if data.length() > limits.max_snapshot_bytes() {
      raise LimitExceeded(
        resource="snapshot-bytes",
        actual=data.length().to_int64(),
        limit=limits.max_snapshot_bytes().to_int64(),
      )
    }
    let reader = BinaryReader::new(data)
    if reader.read_raw(8) != disk_magic {
      raise InvalidMagic
    }
    let version = reader.read_u16()
    if version != mqtt5_snapshot_envelope_version {
      raise UnsupportedEnvelopeVersion(version)
    }
    if reader.read_u16() != 0 {
      raise UnknownFlags(1)
    }
    let length = reader.read_u64_length()
    let checksum = reader.read_u32_bits()
    if length != reader.remaining() {
      raise LengthMismatch(
        declared=length.to_int64(),
        actual=reader.remaining().to_int64(),
      )
    }
    let payload = reader.read_raw(length)
    if crc32(payload) != checksum {
      raise ChecksumMismatch(expected=checksum, actual=crc32(payload))
    }
    Ok(v5_read_payload(BinaryReader::new(payload), limits))
  } catch {
    error => Err(error)
  }
}
