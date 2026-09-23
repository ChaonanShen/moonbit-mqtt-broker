///|
let wal_segment_magic : Bytes = b"MBMWAL01"

///|
let wal_envelope_version : Int = 1

///|
pub(all) struct WalTransaction {
  lsn : Int64
  delta : Bytes
} derive(Eq, Debug)

///|
pub(all) struct WalBatch {
  previous_lsn : Int64
  transactions : Array[WalTransaction]
} derive(Eq, Debug)

///|
pub(all) struct WalSegmentHeader {
  segment_id : Int64
  first_lsn : Int64
  previous_lsn : Int64
  logical_schema : Int
} derive(Eq, Debug)

///|
fn wal_corrupt(field : String, offset : Int) -> PersistenceError {
  InvalidValue(field="wal-" + field, offset~)
}

///|
pub fn encode_wal_segment_header(
  header : WalSegmentHeader,
) -> Result[Bytes, PersistenceError] {
  try {
    if header.segment_id < 1L ||
      header.first_lsn < 1L ||
      header.first_lsn - 1L != header.previous_lsn ||
      header.logical_schema != 3 {
      raise wal_corrupt("segment-header", 0)
    }
    let writer = BinaryWriter::new(max_bytes=40)
    writer.write_raw(wal_segment_magic)
    writer.write_u16(wal_envelope_version, "wal-version")
    writer.write_u16(header.logical_schema, "wal-logical-schema")
    writer.write_positive_i64(header.segment_id, "wal-segment-id")
    writer.write_positive_i64(header.first_lsn, "wal-first-lsn")
    writer.write_positive_i64(header.previous_lsn, "wal-previous-lsn")
    let prefix = writer.finish()
    writer.write_u32_bits(crc32(prefix))
    Ok(writer.finish())
  } catch {
    error => Err(error)
  }
}

///|
pub fn decode_wal_segment_header(
  bytes : Bytes,
) -> Result[WalSegmentHeader, PersistenceError] {
  try {
    let reader = BinaryReader::new(bytes)
    if reader.read_raw(8) != wal_segment_magic {
      raise InvalidMagic
    }
    let version = reader.read_u16()
    if version != wal_envelope_version {
      raise UnsupportedEnvelopeVersion(version)
    }
    let logical_schema = reader.read_u16()
    if logical_schema != 3 {
      raise wal_corrupt("logical-schema", 10)
    }
    let segment_id = reader.read_positive_i64("wal-segment-id")
    let first_lsn = reader.read_positive_i64("wal-first-lsn")
    let previous_lsn = reader.read_positive_i64("wal-previous-lsn")
    let expected = reader.read_u32_bits()
    if reader.remaining() != 0 {
      raise TrailingData(offset=reader.position())
    }
    let actual = crc32(bytes[:36])
    if actual != expected {
      raise ChecksumMismatch(expected~, actual~)
    }
    if segment_id < 1L || first_lsn < 1L || first_lsn - 1L != previous_lsn {
      raise wal_corrupt("segment-header", 0)
    }
    Ok({ segment_id, first_lsn, previous_lsn, logical_schema })
  } catch {
    error => Err(error)
  }
}

///|
fn encode_wal_frame(
  tag : Int,
  body : Bytes,
  max_bytes : Int,
) -> Bytes raise PersistenceError {
  let writer = BinaryWriter::new(max_bytes~)
  writer.write_u8(tag, "wal-frame-tag")
  writer.write_u32(body.length(), "wal-frame-length")
  writer.write_raw(body)
  let prefix = writer.finish()
  writer.write_u32_bits(crc32(prefix))
  writer.finish()
}

///|
pub fn encode_wal_batch(
  batch : WalBatch,
  max_bytes? : Int = 8388608,
  max_transaction_bytes? : Int = 4194304,
) -> Result[Bytes, PersistenceError] {
  try {
    if max_bytes < 46 ||
      max_transaction_bytes < 1 ||
      max_transaction_bytes > 2147483635 ||
      batch.previous_lsn < 0L ||
      batch.transactions.length().to_int64() >
      9223372036854775807L - batch.previous_lsn ||
      batch.transactions.is_empty() {
      raise InvalidConfiguration("invalid WAL batch bounds")
    }
    let writer = BinaryWriter::new(max_bytes~)
    for index in 0..<batch.transactions.length() {
      let transaction = batch.transactions[index]
      let expected_lsn = batch.previous_lsn + index.to_int64() + 1L
      if transaction.lsn != expected_lsn ||
        transaction.delta.length() > max_transaction_bytes {
        raise wal_corrupt("transaction-order-or-size", writer.bytes.length())
      }
      let body = BinaryWriter::new(max_bytes=max_transaction_bytes + 12)
      body.write_positive_i64(transaction.lsn, "wal-transaction-lsn")
      body.write_bytes(transaction.delta)
      writer.write_raw(encode_wal_frame(1, body.finish(), max_bytes))
    }
    let transaction_bytes = writer.finish()
    let commit = BinaryWriter::new(max_bytes=32)
    commit.write_positive_i64(batch.previous_lsn + 1L, "wal-first-lsn")
    commit.write_positive_i64(
      batch.previous_lsn + batch.transactions.length().to_int64(),
      "wal-last-lsn",
    )
    commit.write_u32(batch.transactions.length(), "wal-transaction-count")
    commit.write_positive_i64(batch.previous_lsn, "wal-previous-lsn")
    commit.write_u32_bits(crc32(transaction_bytes))
    writer.write_raw(encode_wal_frame(2, commit.finish(), max_bytes))
    Ok(writer.finish())
  } catch {
    error => Err(error)
  }
}

///|
pub fn decode_wal_batch(
  bytes : Bytes,
  previous_lsn : Int64,
  max_bytes? : Int = 8388608,
  max_transaction_bytes? : Int = 4194304,
) -> Result[WalBatch, PersistenceError] {
  try {
    if bytes.length() > max_bytes ||
      max_transaction_bytes < 1 ||
      max_transaction_bytes > 2147483635 ||
      previous_lsn < 0L {
      raise InvalidConfiguration("invalid WAL batch bounds")
    }
    let reader = BinaryReader::new(bytes)
    let transactions : Array[WalTransaction] = []
    let mut committed = false
    let mut transaction_end = 0
    while reader.remaining() > 0 {
      let frame_start = reader.position()
      let tag = reader.read_u8()
      let length = reader.read_u32("wal-frame-length")
      if (tag == 1 && length > max_transaction_bytes + 12) ||
        (tag == 2 && length != 32) {
        raise wal_corrupt("frame-too-large", frame_start)
      }
      let body = reader.read_raw(length)
      let expected_crc = reader.read_u32_bits()
      let actual_crc = crc32(bytes[frame_start:reader.position() - 4])
      if expected_crc != actual_crc {
        raise ChecksumMismatch(expected=expected_crc, actual=actual_crc)
      }
      if tag == 1 && !committed {
        let txn = BinaryReader::new(body)
        let lsn = txn.read_positive_i64("wal-transaction-lsn")
        let delta = txn.read_bytes(max_transaction_bytes)
        if txn.remaining() != 0 ||
          previous_lsn >=
          9223372036854775807L - transactions.length().to_int64() ||
          lsn != previous_lsn + transactions.length().to_int64() + 1L {
          raise wal_corrupt("transaction-sequence", frame_start)
        }
        transactions.push({ lsn, delta })
        transaction_end = reader.position()
      } else if tag == 2 && !committed {
        let commit = BinaryReader::new(body)
        let first_lsn = commit.read_positive_i64("wal-first-lsn")
        let last_lsn = commit.read_positive_i64("wal-last-lsn")
        let count = commit.read_u32("wal-transaction-count")
        let previous = commit.read_positive_i64("wal-previous-lsn")
        let digest = commit.read_u32_bits()
        if commit.remaining() != 0 ||
          transactions.is_empty() ||
          previous != previous_lsn ||
          first_lsn != previous_lsn + 1L ||
          count != transactions.length() ||
          last_lsn != transactions[transactions.length() - 1].lsn ||
          digest != crc32(bytes[:transaction_end]) {
          raise wal_corrupt("commit-mismatch", frame_start)
        }
        committed = true
      } else {
        raise wal_corrupt("frame-order-or-type", frame_start)
      }
    }
    if !committed {
      raise wal_corrupt("missing-commit", reader.position())
    }
    Ok({ previous_lsn, transactions })
  } catch {
    error => Err(error)
  }
}
