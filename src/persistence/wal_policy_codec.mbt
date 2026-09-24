///|
let wal_policy_magic : Bytes = b"MBMPOL01"

///|
pub(all) struct WalPolicyState {
  sequence : Int64
  fingerprint : Bytes
  reconcile_pending : Bool
} derive(Eq, Debug)

///|
pub(all) enum WalPolicyTransition {
  PolicyActivated
  PolicyReconciled
} derive(Eq, Debug)

///|
pub(all) struct WalPolicyRecord {
  transition : WalPolicyTransition
  sequence : Int64
  fingerprint : Bytes
} derive(Eq)

///|
/// A policy record is a distinct WAL payload, never an empty business delta.
/// Older readers fail its magic instead of silently ignoring a security gate.
pub fn encode_wal_policy_record(
  record : WalPolicyRecord,
) -> Result[Bytes, PersistenceError] {
  try {
    if record.sequence < 1L || record.fingerprint.length() != 32 {
      raise InvalidConfiguration("invalid policy record")
    }
    let writer = BinaryWriter::new(max_bytes=57)
    writer.write_raw(wal_policy_magic)
    writer.write_u16(1, "policy-record-version")
    writer.write_u16(4, "policy-logical-schema")
    writer.write_u8(
      match record.transition {
        PolicyActivated => 1
        PolicyReconciled => 2
      },
      "policy-transition",
    )
    writer.write_positive_i64(record.sequence, "policy-sequence")
    writer.write_raw(record.fingerprint)
    let prefix = writer.finish()
    writer.write_u32_bits(crc32(prefix))
    Ok(writer.finish())
  } catch {
    error => Err(error)
  }
}

///|
pub fn decode_wal_policy_record(
  data : Bytes,
) -> Result[WalPolicyRecord, PersistenceError] {
  try {
    if data.length() != 57 {
      raise wal_corrupt("policy-record-length", 0)
    }
    let reader = BinaryReader::new(data)
    if reader.read_raw(8) != wal_policy_magic {
      raise InvalidMagic
    }
    let version = reader.read_u16()
    if version != 1 {
      raise UnsupportedEnvelopeVersion(version)
    }
    if reader.read_u16() != 4 {
      raise wal_corrupt("policy-logical-schema", 10)
    }
    let transition = match reader.read_u8() {
      1 => PolicyActivated
      2 => PolicyReconciled
      _ => raise wal_corrupt("policy-transition", 12)
    }
    let sequence = reader.read_positive_i64("policy-sequence")
    let fingerprint = reader.read_raw(32)
    let expected = reader.read_u32_bits()
    if reader.remaining() != 0 {
      raise TrailingData(offset=reader.position())
    }
    let actual = crc32(data[:53])
    if actual != expected {
      raise ChecksumMismatch(expected~, actual~)
    }
    Ok({ transition, sequence, fingerprint })
  } catch {
    error => Err(error)
  }
}

///|
fn is_wal_policy_record(data : Bytes) -> Bool {
  data.length() >= 8 && data[:8] == wal_policy_magic
}

///|
fn apply_policy_record(
  current : WalPolicyState?,
  record : WalPolicyRecord,
) -> Result[WalPolicyState, PersistenceError] {
  match record.transition {
    PolicyActivated => {
      let expected = match current {
        None => 1L
        Some(value) if !value.reconcile_pending &&
          value.sequence < 9223372036854775807L => value.sequence + 1L
        _ => return Err(InvalidValue(field="wal-policy-order", offset=0))
      }
      if record.sequence != expected {
        return Err(InvalidValue(field="wal-policy-sequence", offset=0))
      }
      Ok({
        sequence: record.sequence,
        fingerprint: record.fingerprint,
        reconcile_pending: true,
      })
    }
    PolicyReconciled =>
      match current {
        Some(value) if value.sequence == record.sequence &&
          value.reconcile_pending &&
          value.fingerprint == record.fingerprint =>
          Ok({ ..value, reconcile_pending: false })
        _ => Err(InvalidValue(field="wal-policy-order", offset=0))
      }
  }
}

///|
fn fold_wal_policy_batches(
  initial : WalPolicyState?,
  batches : Array[WalBatch],
  policy_required : Bool,
) -> Result[WalPolicyState?, PersistenceError] {
  let mut current = initial
  for batch in batches {
    for transaction in batch.transactions {
      if is_wal_policy_record(transaction.delta) {
        if !policy_required {
          return Err(InvalidValue(field="wal-policy-capability", offset=0))
        }
        let record = match decode_wal_policy_record(transaction.delta) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        current = match apply_policy_record(current, record) {
          Ok(value) => Some(value)
          Err(error) => return Err(error)
        }
      }
    }
  }
  Ok(current)
}
