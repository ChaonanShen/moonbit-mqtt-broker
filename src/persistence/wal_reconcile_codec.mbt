///|
let wal_reconcile_magic : Bytes = b"MBMREC01"

///|
pub fn is_wal_reconcile_record(data : Bytes) -> Bool {
  data.length() >= 8 && data[:8] == wal_reconcile_magic
}

///|
/// One bounded security cleanup action. The queue payload is never copied
/// into this record; the committed WAL order identifies its current head.
pub fn encode_wal_reconcile(
  delta : @router.DurableReconcileDelta,
) -> Result[Bytes, PersistenceError] {
  try {
    if delta.client_id == "" || delta.expected_generation < 1L {
      raise InvalidConfiguration("invalid reconcile identity")
    }
    let writer = BinaryWriter::new(max_bytes=131200)
    writer.write_raw(wal_reconcile_magic)
    writer.write_u16(1, "reconcile-version")
    writer.write_u16(4, "reconcile-logical-schema")
    match delta.change {
      DropSubscription(filter) => {
        if filter == "" {
          raise InvalidConfiguration("empty reconcile filter")
        }
        writer.write_u8(1, "reconcile-kind")
        writer.write_string(delta.client_id)
        writer.write_positive_i64(
          delta.expected_generation,
          "reconcile-generation",
        )
        writer.write_string(filter)
      }
      DropPendingHead(topic, qos, payload_bytes) => {
        if topic == "" || (qos != 1 && qos != 2) || payload_bytes < 0 {
          raise InvalidConfiguration("invalid pending reconcile descriptor")
        }
        writer.write_u8(2, "reconcile-kind")
        writer.write_string(delta.client_id)
        writer.write_positive_i64(
          delta.expected_generation,
          "reconcile-generation",
        )
        writer.write_string(topic)
        writer.write_u8(qos, "reconcile-qos")
        writer.write_u32(payload_bytes, "reconcile-payload-bytes")
      }
    }
    let prefix = writer.finish()
    writer.write_u32_bits(crc32(prefix))
    Ok(writer.finish())
  } catch {
    error => Err(error)
  }
}

///|
pub fn decode_wal_reconcile(
  data : Bytes,
) -> Result[@router.DurableReconcileDelta, PersistenceError] {
  try {
    if data.length() > 131200 {
      raise LimitExceeded(
        resource="wal-reconcile-bytes",
        actual=data.length().to_int64(),
        limit=131200L,
      )
    }
    let reader = BinaryReader::new(data)
    if reader.read_raw(8) != wal_reconcile_magic {
      raise InvalidMagic
    }
    let version = reader.read_u16()
    if version != 1 {
      raise UnsupportedEnvelopeVersion(version)
    }
    if reader.read_u16() != 4 {
      raise wal_corrupt("reconcile-schema", 10)
    }
    let kind = reader.read_u8()
    let client_id = reader.read_string()
    let expected_generation = reader.read_positive_i64("reconcile-generation")
    let change : @router.DurablePolicyChange = match kind {
      1 => {
        let filter = reader.read_string()
        if filter == "" {
          raise wal_corrupt("reconcile-filter", reader.position())
        }
        DropSubscription(filter)
      }
      2 => {
        let topic = reader.read_string()
        let qos = reader.read_u8()
        let payload_bytes = reader.read_u32("reconcile-payload-bytes")
        if topic == "" || (qos != 1 && qos != 2) {
          raise wal_corrupt("reconcile-pending", reader.position())
        }
        DropPendingHead(topic, qos, payload_bytes)
      }
      _ => raise wal_corrupt("reconcile-kind", 12)
    }
    let expected = reader.read_u32_bits()
    if reader.remaining() != 0 {
      raise TrailingData(offset=reader.position())
    }
    let actual = crc32(data[:data.length() - 4])
    if actual != expected {
      raise ChecksumMismatch(expected~, actual~)
    }
    if client_id == "" {
      raise wal_corrupt("reconcile-client", 13)
    }
    Ok({ client_id, expected_generation, change })
  } catch {
    error => Err(error)
  }
}
