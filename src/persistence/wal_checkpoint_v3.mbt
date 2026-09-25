///|
pub(all) struct WalCheckpointV5 {
  generation : Int64
  lsn : Int64
  identities : Array[WalSessionIdentity]
  required_features : UInt
  policy : WalPolicyState?
  snapshot : @router.BrokerSnapshotV5
} derive(Eq, Debug)

///|
fn validate_wal_checkpoint_v5(
  value : WalCheckpointV5,
) -> Unit raise PersistenceError {
  if value.generation < 1L ||
    value.lsn < 0L ||
    value.identities.length() != value.snapshot.sessions.length() ||
    !supported_mqtt5_features(value.required_features) ||
    (value.required_features & feature_mqtt5_model) == 0U ||
    ((value.required_features & feature_policy_gate) != 0U) !=
    (value.policy is Some(_)) {
    raise wal_corrupt("checkpoint-v5-header", 0)
  }
  for index in 0..<value.identities.length() {
    if value.identities[index].client_id !=
      value.snapshot.sessions[index].client_id ||
      value.identities[index].generation < 1L {
      raise wal_corrupt("checkpoint-v5-identity", index)
    }
  }
}

///|
pub fn encode_wal_checkpoint_v5(
  value : WalCheckpointV5,
  max_checkpoint_bytes? : Int = 134217728,
  max_snapshot_bytes? : Int = 67108864,
) -> Result[Bytes, PersistenceError] {
  try {
    validate_wal_checkpoint_v5(value)
    let snapshot = match
      encode_snapshot_v5(value.snapshot, max_snapshot_bytes~) {
      Ok(bytes) => bytes
      Err(error) => raise error
    }
    let writer = BinaryWriter::new(max_bytes=max_checkpoint_bytes)
    writer.write_raw(wal_checkpoint_magic)
    writer.write_u16(mqtt5_checkpoint_version, "checkpoint-version")
    writer.write_u16(mqtt5_wal_logical_schema, "checkpoint-logical-schema")
    writer.write_u32_bits(value.required_features)
    writer.write_positive_i64(value.generation, "checkpoint-generation")
    writer.write_positive_i64(value.lsn, "checkpoint-lsn")
    writer.write_u32(value.identities.length(), "identity-count")
    for identity in value.identities {
      writer.write_string(identity.client_id)
      writer.write_positive_i64(identity.generation, "session-generation")
    }
    if value.policy is Some(policy) {
      writer.write_positive_i64(policy.sequence, "policy-sequence")
      writer.write_raw(policy.fingerprint)
      writer.write_u8(
        if policy.reconcile_pending {
          1
        } else {
          0
        },
        "reconcile-pending",
      )
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
pub fn decode_wal_checkpoint_v5(
  data : Bytes,
  limits : SnapshotDecodeLimits,
  max_checkpoint_bytes? : Int = 134217728,
) -> Result[WalCheckpointV5, PersistenceError] {
  try {
    if data.length() > max_checkpoint_bytes {
      raise LimitExceeded(
        resource="checkpoint-bytes",
        actual=data.length().to_int64(),
        limit=max_checkpoint_bytes.to_int64(),
      )
    }
    let reader = BinaryReader::new(data)
    if reader.read_raw(8) != wal_checkpoint_magic {
      raise InvalidMagic
    }
    let version = reader.read_u16()
    if version != mqtt5_checkpoint_version {
      raise UnsupportedEnvelopeVersion(version)
    }
    if reader.read_u16() != mqtt5_wal_logical_schema {
      raise wal_corrupt("checkpoint-logical-schema", 10)
    }
    let required_features = reader.read_u32_bits()
    let generation = reader.read_positive_i64("checkpoint-generation")
    let lsn = reader.read_positive_i64("checkpoint-lsn")
    let count = checked_count(
      reader,
      "identity-count",
      limits.broker_config().max_sessions(),
    )
    let identities : Array[WalSessionIdentity] = []
    for _ in 0..<count {
      identities.push({
        client_id: reader.read_string(),
        generation: reader.read_positive_i64("session-generation"),
      })
    }
    let policy = if (required_features & feature_policy_gate) != 0U {
      let sequence = reader.read_positive_i64("policy-sequence")
      let fingerprint = reader.read_raw(32)
      let flag = reader.read_u8()
      if flag > 1 {
        raise wal_corrupt("reconcile-pending", reader.position())
      }
      Some(WalPolicyState::{
        sequence,
        fingerprint,
        reconcile_pending: flag == 1,
      })
    } else {
      None
    }
    let snapshot_bytes = reader.read_bytes(limits.max_snapshot_bytes())
    if reader.remaining() != 4 {
      raise TrailingData(offset=reader.position())
    }
    let expected = reader.read_u32_bits()
    let actual = crc32(data[:data.length() - 4])
    if expected != actual {
      raise ChecksumMismatch(expected~, actual~)
    }
    let snapshot = match decode_snapshot_v5(snapshot_bytes, limits) {
      Ok(value) => value
      Err(error) => raise error
    }
    let value : WalCheckpointV5 = {
      generation,
      lsn,
      identities,
      required_features,
      policy,
      snapshot,
    }
    validate_wal_checkpoint_v5(value)
    Ok(value)
  } catch {
    error => Err(error)
  }
}
