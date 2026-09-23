///|
let wal_checkpoint_magic : Bytes = b"MBMCKP01"

///|
pub(all) struct WalSessionIdentity {
  client_id : String
  generation : Int64
} derive(Eq, Debug)

///|
pub(all) struct WalCheckpoint {
  generation : Int64
  lsn : Int64
  identities : Array[WalSessionIdentity]
  snapshot : @router.BrokerSnapshotV3
} derive(Eq, Debug)

///|
fn validate_wal_checkpoint(
  checkpoint : WalCheckpoint,
) -> Unit raise PersistenceError {
  if checkpoint.generation < 1L ||
    checkpoint.lsn < 0L ||
    checkpoint.snapshot.version != 3 ||
    checkpoint.identities.length() != checkpoint.snapshot.sessions.length() {
    raise wal_corrupt("checkpoint-header-or-identities", 0)
  }
  for index in 0..<checkpoint.identities.length() {
    let identity = checkpoint.identities[index]
    if identity.generation < 1L ||
      identity.client_id != checkpoint.snapshot.sessions[index].client_id {
      raise wal_corrupt("checkpoint-identity", index)
    }
  }
}

///|
pub fn encode_wal_checkpoint(
  checkpoint : WalCheckpoint,
  max_checkpoint_bytes? : Int = 134217728,
  max_snapshot_bytes? : Int = 67108864,
) -> Result[Bytes, PersistenceError] {
  try {
    validate_wal_checkpoint(checkpoint)
    if max_checkpoint_bytes < 48 ||
      max_snapshot_bytes < 24 ||
      max_checkpoint_bytes > 2147483647 {
      raise InvalidConfiguration("invalid WAL checkpoint limits")
    }
    let snapshot = match
      encode_snapshot(checkpoint.snapshot, max_snapshot_bytes~) {
      Ok(value) => value
      Err(error) => raise error
    }
    let writer = BinaryWriter::new(max_bytes=max_checkpoint_bytes)
    writer.write_raw(wal_checkpoint_magic)
    writer.write_u16(1, "wal-checkpoint-version")
    writer.write_u16(3, "wal-logical-schema")
    writer.write_positive_i64(
      checkpoint.generation,
      "wal-checkpoint-generation",
    )
    writer.write_positive_i64(checkpoint.lsn, "wal-checkpoint-lsn")
    writer.write_u32(checkpoint.identities.length(), "wal-identity-count")
    for identity in checkpoint.identities {
      writer.write_string(identity.client_id)
      writer.write_positive_i64(identity.generation, "wal-session-generation")
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
pub fn decode_wal_checkpoint(
  data : Bytes,
  limits : SnapshotDecodeLimits,
  max_checkpoint_bytes? : Int = 134217728,
  workspace? : DecodeWorkspace,
) -> Result[WalCheckpoint, PersistenceError] {
  try {
    if data.length() > max_checkpoint_bytes {
      raise LimitExceeded(
        resource="wal-checkpoint-bytes",
        actual=data.length().to_int64(),
        limit=max_checkpoint_bytes.to_int64(),
      )
    }
    let reader = BinaryReader::new(data)
    if reader.read_raw(8) != wal_checkpoint_magic {
      raise InvalidMagic
    }
    let version = reader.read_u16()
    if version != 1 {
      raise UnsupportedEnvelopeVersion(version)
    }
    if reader.read_u16() != 3 {
      raise wal_corrupt("checkpoint-logical-schema", 10)
    }
    let generation = reader.read_positive_i64("wal-checkpoint-generation")
    let lsn = reader.read_positive_i64("wal-checkpoint-lsn")
    let count = reader.read_u32("wal-identity-count")
    if count > limits.broker_config().max_sessions() {
      raise LimitExceeded(
        resource="wal-identity-count",
        actual=count.to_int64(),
        limit=limits.broker_config().max_sessions().to_int64(),
      )
    }
    let identities : Array[WalSessionIdentity] = []
    for _ in 0..<count {
      identities.push({
        client_id: reader.read_string(),
        generation: reader.read_positive_i64("wal-session-generation"),
      })
    }
    let snapshot_bytes = reader.read_bytes(limits.max_snapshot_bytes())
    let expected = reader.read_u32_bits()
    if reader.remaining() != 0 {
      raise TrailingData(offset=reader.position())
    }
    let actual = crc32(data[:data.length() - 4])
    if expected != actual {
      raise ChecksumMismatch(expected~, actual~)
    }
    let snapshot = match decode_snapshot(snapshot_bytes, limits, workspace?) {
      Ok(value) => value
      Err(error) => raise error
    }
    let checkpoint = { generation, lsn, identities, snapshot }
    validate_wal_checkpoint(checkpoint)
    Ok(checkpoint)
  } catch {
    error => Err(error)
  }
}
