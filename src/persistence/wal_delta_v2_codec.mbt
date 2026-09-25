///|
let wal_delta_v2_magic : Bytes = b"MBMDLT01"

///|
pub fn encode_durable_delta_v5(
  delta : @router.DurableDeltaV5,
  max_bytes? : Int = 4194304,
) -> Result[Bytes, PersistenceError] {
  try {
    if max_bytes < 64 {
      raise InvalidConfiguration("MQTT5 delta limit below header")
    }
    let writer = BinaryWriter::new(max_bytes~)
    writer.write_raw(wal_delta_v2_magic)
    writer.write_u16(mqtt5_business_delta_version, "delta-version")
    writer.write_u16(mqtt5_wal_logical_schema, "delta-logical-schema")
    v5_write_optional_i64(writer, delta.new_clock_floor)
    writer.write_u32(delta.id_floors.length(), "id-floor-count")
    let seen_floors : Map[Int, Bool] = Map([])
    for floor in delta.id_floors {
      if floor.kind < 1 ||
        floor.kind > 6 ||
        floor.new_floor < 1L ||
        seen_floors.contains(floor.kind) {
        raise InvalidValue(field="id-floor", offset=writer.bytes.length())
      }
      seen_floors.set(floor.kind, true)
      writer.write_u8(floor.kind, "id-floor-kind")
      writer.write_positive_i64(floor.new_floor, "id-floor")
    }
    writer.write_u32(delta.session_puts.length(), "session-put-count")
    for put in delta.session_puts {
      writer.write_positive_i64(
        put.expected_incarnation,
        "expected-incarnation",
      )
      writer.write_positive_i64(put.expected_revision, "expected-revision")
      v5_write_session(writer, put.session)
    }
    writer.write_u32(delta.session_deletes.length(), "session-delete-count")
    for deletion in delta.session_deletes {
      writer.write_string(deletion.client_id)
      writer.write_positive_i64(
        deletion.expected_incarnation,
        "expected-incarnation",
      )
      writer.write_positive_i64(deletion.expected_revision, "expected-revision")
    }
    writer.write_u32(delta.group_puts.length(), "group-put-count")
    for put in delta.group_puts {
      writer.write_positive_i64(
        put.expected_incarnation,
        "expected-incarnation",
      )
      writer.write_positive_i64(put.expected_revision, "expected-revision")
      v5_write_group(writer, put.group)
    }
    writer.write_u32(delta.group_deletes.length(), "group-delete-count")
    for deletion in delta.group_deletes {
      writer.write_positive_i64(deletion.id, "group-id")
      writer.write_positive_i64(
        deletion.expected_incarnation,
        "expected-incarnation",
      )
      writer.write_positive_i64(deletion.expected_revision, "expected-revision")
    }
    writer.write_u32(delta.retained_puts.length(), "retained-put-count")
    for put in delta.retained_puts {
      writer.write_positive_i64(put.expected_revision, "expected-revision")
      writer.write_positive_i64(put.retained.revision, "retained-revision")
      v5_write_message(writer, put.retained.message)
    }
    writer.write_u32(delta.retained_deletes.length(), "retained-delete-count")
    for deletion in delta.retained_deletes {
      writer.write_string(deletion.topic)
      writer.write_positive_i64(deletion.expected_revision, "expected-revision")
    }
    writer.write_u32(delta.will_puts.length(), "will-put-count")
    for put in delta.will_puts {
      writer.write_positive_i64(put.expected_revision, "expected-revision")
      v5_write_will(writer, put.will)
    }
    writer.write_u32(delta.will_deletes.length(), "will-delete-count")
    for deletion in delta.will_deletes {
      writer.write_positive_i64(deletion.id, "will-id")
      writer.write_positive_i64(deletion.expected_revision, "expected-revision")
    }
    let prefix = writer.finish()
    writer.write_u32_bits(crc32(prefix))
    Ok(writer.finish())
  } catch {
    error => Err(error)
  }
}

///|
pub fn decode_durable_delta_v5(
  data : Bytes,
  limits : SnapshotDecodeLimits,
  max_bytes? : Int = 4194304,
) -> Result[@router.DurableDeltaV5, PersistenceError] {
  try {
    if data.length() > max_bytes {
      raise LimitExceeded(
        resource="wal-delta-bytes",
        actual=data.length().to_int64(),
        limit=max_bytes.to_int64(),
      )
    }
    let reader = BinaryReader::new(data)
    if reader.read_raw(8) != wal_delta_v2_magic {
      raise InvalidMagic
    }
    if reader.read_u16() != mqtt5_business_delta_version {
      raise UnsupportedEnvelopeVersion(2)
    }
    if reader.read_u16() != mqtt5_wal_logical_schema {
      raise InvalidValue(field="delta-logical-schema", offset=10)
    }
    let new_clock_floor = v5_read_optional_i64(reader)
    let floor_count = checked_count(reader, "id-floor-count", 6)
    let id_floors : Array[@router.Mqtt5IdFloor] = []
    let seen_floors : Map[Int, Bool] = Map([])
    for _ in 0..<floor_count {
      let kind = reader.read_u8()
      let new_floor = reader.read_positive_i64("id-floor")
      if kind < 1 || kind > 6 || new_floor < 1L || seen_floors.contains(kind) {
        raise InvalidValue(field="id-floor", offset=reader.position())
      }
      seen_floors.set(kind, true)
      id_floors.push({ kind, new_floor })
    }
    let broker = limits.broker_config()
    let session_put_count = checked_count(
      reader,
      "session-put-count",
      broker.max_sessions(),
    )
    let session_puts : Array[@router.Mqtt5SessionPut] = []
    for _ in 0..<session_put_count {
      session_puts.push({
        expected_incarnation: reader.read_positive_i64("expected-incarnation"),
        expected_revision: reader.read_positive_i64("expected-revision"),
        session: v5_read_session(reader, limits),
      })
    }
    let session_delete_count = checked_count(
      reader,
      "session-delete-count",
      broker.max_sessions(),
    )
    let session_deletes : Array[@router.Mqtt5SessionDelete] = []
    for _ in 0..<session_delete_count {
      session_deletes.push({
        client_id: reader.read_string(),
        expected_incarnation: reader.read_positive_i64("expected-incarnation"),
        expected_revision: reader.read_positive_i64("expected-revision"),
      })
    }
    let group_put_count = checked_count(reader, "group-put-count", 1024)
    let group_puts : Array[@router.Mqtt5GroupPut] = []
    for _ in 0..<group_put_count {
      group_puts.push({
        expected_incarnation: reader.read_positive_i64("expected-incarnation"),
        expected_revision: reader.read_positive_i64("expected-revision"),
        group: v5_read_group(reader),
      })
    }
    let group_delete_count = checked_count(reader, "group-delete-count", 1024)
    let group_deletes : Array[@router.Mqtt5GroupDelete] = []
    for _ in 0..<group_delete_count {
      group_deletes.push({
        id: reader.read_positive_i64("group-id"),
        expected_incarnation: reader.read_positive_i64("expected-incarnation"),
        expected_revision: reader.read_positive_i64("expected-revision"),
      })
    }
    let retained_put_count = checked_count(
      reader,
      "retained-put-count",
      broker.max_retained_messages(),
    )
    let retained_puts : Array[@router.Mqtt5RetainedPut] = []
    for _ in 0..<retained_put_count {
      retained_puts.push({
        expected_revision: reader.read_positive_i64("expected-revision"),
        retained: {
          revision: reader.read_positive_i64("retained-revision"),
          message: v5_read_message(reader, limits.max_message_payload_bytes()),
        },
      })
    }
    let retained_delete_count = checked_count(
      reader,
      "retained-delete-count",
      broker.max_retained_messages(),
    )
    let retained_deletes : Array[@router.Mqtt5RetainedDelete] = []
    for _ in 0..<retained_delete_count {
      retained_deletes.push({
        topic: reader.read_string(),
        expected_revision: reader.read_positive_i64("expected-revision"),
      })
    }
    let will_put_count = checked_count(
      reader,
      "will-put-count",
      broker.max_sessions() + 1024,
    )
    let will_puts : Array[@router.Mqtt5WillPut] = []
    for _ in 0..<will_put_count {
      will_puts.push({
        expected_revision: reader.read_positive_i64("expected-revision"),
        will: v5_read_will(reader, limits.max_message_payload_bytes()),
      })
    }
    let will_delete_count = checked_count(
      reader,
      "will-delete-count",
      broker.max_sessions() + 1024,
    )
    let will_deletes : Array[@router.Mqtt5WillDelete] = []
    for _ in 0..<will_delete_count {
      will_deletes.push({
        id: reader.read_positive_i64("will-id"),
        expected_revision: reader.read_positive_i64("expected-revision"),
      })
    }
    if reader.remaining() != 4 {
      raise TrailingData(offset=reader.position())
    }
    let expected = reader.read_u32_bits()
    let prefix = data[0:data.length() - 4].to_owned()
    let actual = crc32(prefix)
    if expected != actual {
      raise ChecksumMismatch(expected~, actual~)
    }
    Ok({
      new_clock_floor,
      id_floors,
      session_puts,
      session_deletes,
      group_puts,
      group_deletes,
      retained_puts,
      retained_deletes,
      will_puts,
      will_deletes,
    })
  } catch {
    error => Err(error)
  }
}
