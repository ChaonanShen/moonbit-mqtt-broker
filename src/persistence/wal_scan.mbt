///|
pub(all) struct WalSegmentScan {
  header : WalSegmentHeader
  batches : Array[WalBatch]
  committed_lsn : Int64
  committed_bytes : Int
  recovered_tail : Bool
} derive(Eq, Debug)

///|
/// A complete frame with an invalid checksum or semantic value is corruption,
/// including at the end of the active segment. Only an incomplete final frame
/// or complete transactions without a commit can be discarded as an active tail.
pub fn scan_wal_segment(
  data : Bytes,
  active : Bool,
  max_segment_bytes? : Int = 67108864,
  max_batch_bytes? : Int = 4194304,
  max_transaction_bytes? : Int = 1048576,
) -> Result[WalSegmentScan, PersistenceError] {
  try {
    if max_segment_bytes < 40 ||
      max_batch_bytes < 46 ||
      max_transaction_bytes < 1 ||
      max_transaction_bytes > 2147483635 {
      raise InvalidConfiguration("invalid WAL scan limits")
    }
    if data.length() > max_segment_bytes {
      raise LimitExceeded(
        resource="wal-segment-bytes",
        actual=data.length().to_int64(),
        limit=max_segment_bytes.to_int64(),
      )
    }
    if data.length() < 40 {
      raise Truncated(offset=data.length(), needed=40, remaining=0)
    }
    let header = match decode_wal_segment_header(data[:40].to_owned()) {
      Ok(value) => value
      Err(error) => raise error
    }
    let reader = BinaryReader::new(data)
    ignore(reader.read_raw(40))
    let batches : Array[WalBatch] = []
    let mut batch_start = 40
    let mut committed_bytes = 40
    let mut committed_lsn = header.previous_lsn
    let mut incomplete_tail = false
    while reader.remaining() > 0 {
      let frame_start = reader.position()
      if reader.remaining() < 5 {
        incomplete_tail = true
        break
      }
      let tag = reader.read_u8()
      let length = reader.read_u32("wal-frame-length")
      if tag != 1 && tag != 2 {
        raise wal_corrupt("frame-type", frame_start)
      }
      if (tag == 1 && length > max_transaction_bytes + 12) ||
        (tag == 2 && length != 32) ||
        reader.position() - batch_start + length + 4 > max_batch_bytes {
        raise wal_corrupt("frame-limit", frame_start)
      }
      if reader.remaining() < length + 4 {
        incomplete_tail = true
        break
      }
      ignore(reader.read_raw(length))
      let expected_crc = reader.read_u32_bits()
      let actual_crc = crc32(data[frame_start:reader.position() - 4])
      if expected_crc != actual_crc {
        raise ChecksumMismatch(expected=expected_crc, actual=actual_crc)
      }
      if tag == 2 {
        let batch_bytes = data[batch_start:reader.position()].to_owned()
        let batch = match
          decode_wal_batch(
            batch_bytes,
            committed_lsn,
            max_bytes=max_batch_bytes,
            max_transaction_bytes~,
          ) {
          Ok(value) => value
          Err(error) => raise error
        }
        committed_lsn = batch.transactions[batch.transactions.length() - 1].lsn
        batches.push(batch)
        committed_bytes = reader.position()
        batch_start = committed_bytes
      }
    }
    if !active && (incomplete_tail || committed_bytes != data.length()) {
      raise wal_corrupt("sealed-tail", committed_bytes)
    }
    Ok({
      header,
      batches,
      committed_lsn,
      committed_bytes,
      recovered_tail: committed_bytes != data.length(),
    })
  } catch {
    error => Err(error)
  }
}
