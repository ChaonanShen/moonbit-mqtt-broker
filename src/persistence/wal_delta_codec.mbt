///|
let wal_delta_magic : Bytes = b"MBMDLT01"

///|
pub fn encode_durable_delta(
  delta : @router.DurableDelta,
  max_bytes? : Int = 1048576,
) -> Result[Bytes, PersistenceError] {
  try {
    if max_bytes < 64 || max_bytes > 2147483647 {
      raise InvalidConfiguration("invalid durable delta limit")
    }
    let changed : @router.BrokerSnapshotV3 = {
      version: 3,
      sessions: delta.session_puts.map(item => item.session),
      retained: delta.retained_puts,
    }
    let snapshot = match
      encode_snapshot(changed, max_snapshot_bytes=max_bytes) {
      Ok(value) => value
      Err(error) => raise error
    }
    let writer = BinaryWriter::new(max_bytes~)
    writer.write_raw(wal_delta_magic)
    writer.write_u16(1, "wal-delta-version")
    writer.write_u16(3, "wal-logical-schema")
    writer.write_u32(delta.session_puts.length(), "wal-session-put-count")
    for put in delta.session_puts {
      writer.write_positive_i64(
        put.expected_generation,
        "wal-expected-generation",
      )
      writer.write_positive_i64(put.generation, "wal-session-generation")
    }
    writer.write_u32(delta.session_deletes.length(), "wal-session-delete-count")
    for deletion in delta.session_deletes {
      writer.write_string(deletion.client_id)
      writer.write_positive_i64(
        deletion.expected_generation,
        "wal-expected-generation",
      )
    }
    writer.write_u32(
      delta.retained_deletes.length(),
      "wal-retained-delete-count",
    )
    for topic in delta.retained_deletes {
      writer.write_string(topic)
    }
    writer.write_bytes(snapshot)
    let prefix = writer.finish()
    writer.write_u32_bits(crc32(prefix))
    Ok(writer.finish())
  } catch {
    error => Err(error)
  }
}

///|
pub fn decode_durable_delta(
  data : Bytes,
  limits : SnapshotDecodeLimits,
  max_bytes? : Int = 1048576,
) -> Result[@router.DurableDelta, PersistenceError] {
  try {
    if data.length() > max_bytes {
      raise LimitExceeded(
        resource="wal-delta-bytes",
        actual=data.length().to_int64(),
        limit=max_bytes.to_int64(),
      )
    }
    let reader = BinaryReader::new(data)
    if reader.read_raw(8) != wal_delta_magic {
      raise InvalidMagic
    }
    let version = reader.read_u16()
    if version != 1 {
      raise UnsupportedEnvelopeVersion(version)
    }
    if reader.read_u16() != 3 {
      raise wal_corrupt("delta-logical-schema", 10)
    }
    let put_count = reader.read_u32("wal-session-put-count")
    if put_count > limits.broker_config().max_sessions() {
      raise LimitExceeded(
        resource="wal-session-put-count",
        actual=put_count.to_int64(),
        limit=limits.broker_config().max_sessions().to_int64(),
      )
    }
    let put_generations : Array[(Int64, Int64)] = []
    for _ in 0..<put_count {
      put_generations.push(
        (
          reader.read_positive_i64("wal-expected-generation"),
          reader.read_positive_i64("wal-session-generation"),
        ),
      )
    }
    let delete_count = reader.read_u32("wal-session-delete-count")
    if delete_count > limits.broker_config().max_sessions() {
      raise LimitExceeded(
        resource="wal-session-delete-count",
        actual=delete_count.to_int64(),
        limit=limits.broker_config().max_sessions().to_int64(),
      )
    }
    let session_deletes : Array[@router.DurableSessionDelete] = []
    for _ in 0..<delete_count {
      session_deletes.push({
        client_id: reader.read_string(),
        expected_generation: reader.read_positive_i64("wal-expected-generation"),
      })
    }
    let retained_count = reader.read_u32("wal-retained-delete-count")
    if retained_count > limits.broker_config().max_retained_messages() {
      raise LimitExceeded(
        resource="wal-retained-delete-count",
        actual=retained_count.to_int64(),
        limit=limits.broker_config().max_retained_messages().to_int64(),
      )
    }
    let retained_deletes : Array[String] = []
    for _ in 0..<retained_count {
      retained_deletes.push(reader.read_string())
    }
    let snapshot_bytes = reader.read_bytes(max_bytes)
    let expected = reader.read_u32_bits()
    if reader.remaining() != 0 {
      raise TrailingData(offset=reader.position())
    }
    let actual = crc32(data[:data.length() - 4])
    if actual != expected {
      raise ChecksumMismatch(expected~, actual~)
    }
    let changed = match decode_snapshot(snapshot_bytes, limits) {
      Ok(value) => value
      Err(error) => raise error
    }
    if changed.sessions.length() != put_count {
      raise wal_corrupt("delta-put-count", 0)
    }
    let session_puts : Array[@router.DurableSessionPut] = []
    for index in 0..<put_count {
      let (expected_generation, generation) = put_generations[index]
      session_puts.push({
        expected_generation,
        generation,
        session: changed.sessions[index],
      })
    }
    Ok({
      session_puts,
      session_deletes,
      retained_puts: changed.retained,
      retained_deletes,
    })
  } catch {
    error => Err(error)
  }
}
