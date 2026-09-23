///|
let wal_manifest_magic : Bytes = b"MBMMAN01"

///|
pub(all) struct WalSealedSegment {
  segment_id : Int64
  start_lsn : Int64
  end_lsn : Int64
} derive(Eq, Debug)

///|
pub(all) struct WalManifest {
  generation : Int64
  checkpoint_generation : Int64
  checkpoint_lsn : Int64
  sealed_segments : Array[WalSealedSegment]
  active_segment_id : Int64
  active_start_lsn : Int64
} derive(Eq, Debug)

///|
fn validate_wal_manifest(manifest : WalManifest) -> Unit raise PersistenceError {
  if manifest.generation < 1L ||
    manifest.checkpoint_generation < 1L ||
    manifest.checkpoint_lsn < 0L ||
    manifest.active_segment_id < 1L ||
    manifest.sealed_segments.length() > 512 ||
    manifest.checkpoint_lsn >= 9223372036854775807L {
    raise wal_corrupt("manifest-header", 0)
  }
  let mut previous_id = 0L
  let mut previous_lsn = manifest.checkpoint_lsn
  for segment in manifest.sealed_segments {
    if segment.segment_id <= previous_id ||
      segment.segment_id >= manifest.active_segment_id ||
      previous_lsn >= 9223372036854775807L ||
      segment.start_lsn != previous_lsn + 1L ||
      segment.end_lsn < segment.start_lsn {
      raise wal_corrupt("manifest-segment-chain", 0)
    }
    previous_id = segment.segment_id
    previous_lsn = segment.end_lsn
  }
  if previous_lsn >= 9223372036854775807L ||
    manifest.active_start_lsn != previous_lsn + 1L {
    raise wal_corrupt("manifest-active-chain", 0)
  }
}

///|
pub fn encode_wal_manifest(
  manifest : WalManifest,
) -> Result[Bytes, PersistenceError] {
  try {
    validate_wal_manifest(manifest)
    let writer = BinaryWriter::new(max_bytes=32768)
    writer.write_raw(wal_manifest_magic)
    writer.write_u16(1, "wal-manifest-version")
    writer.write_u16(3, "wal-logical-schema")
    writer.write_positive_i64(manifest.generation, "wal-manifest-generation")
    writer.write_positive_i64(
      manifest.checkpoint_generation,
      "wal-checkpoint-generation",
    )
    writer.write_positive_i64(manifest.checkpoint_lsn, "wal-checkpoint-lsn")
    writer.write_u32(manifest.sealed_segments.length(), "wal-sealed-count")
    for segment in manifest.sealed_segments {
      writer.write_positive_i64(segment.segment_id, "wal-segment-id")
      writer.write_positive_i64(segment.start_lsn, "wal-segment-start")
      writer.write_positive_i64(segment.end_lsn, "wal-segment-end")
    }
    writer.write_positive_i64(manifest.active_segment_id, "wal-active-id")
    writer.write_positive_i64(manifest.active_start_lsn, "wal-active-start")
    let prefix = writer.finish()
    writer.write_u32_bits(crc32(prefix))
    Ok(writer.finish())
  } catch {
    error => Err(error)
  }
}

///|
pub fn decode_wal_manifest(
  data : Bytes,
) -> Result[WalManifest, PersistenceError] {
  try {
    if data.length() > 32768 {
      raise LimitExceeded(
        resource="wal-manifest-bytes",
        actual=data.length().to_int64(),
        limit=32768L,
      )
    }
    let reader = BinaryReader::new(data)
    if reader.read_raw(8) != wal_manifest_magic {
      raise InvalidMagic
    }
    let version = reader.read_u16()
    if version != 1 {
      raise UnsupportedEnvelopeVersion(version)
    }
    if reader.read_u16() != 3 {
      raise wal_corrupt("manifest-logical-schema", 10)
    }
    let generation = reader.read_positive_i64("wal-manifest-generation")
    let checkpoint_generation = reader.read_positive_i64(
      "wal-checkpoint-generation",
    )
    let checkpoint_lsn = reader.read_positive_i64("wal-checkpoint-lsn")
    let count = reader.read_u32("wal-sealed-count")
    if count > 512 {
      raise LimitExceeded(
        resource="wal-sealed-count",
        actual=count.to_int64(),
        limit=512L,
      )
    }
    let sealed_segments : Array[WalSealedSegment] = []
    for _ in 0..<count {
      sealed_segments.push({
        segment_id: reader.read_positive_i64("wal-segment-id"),
        start_lsn: reader.read_positive_i64("wal-segment-start"),
        end_lsn: reader.read_positive_i64("wal-segment-end"),
      })
    }
    let active_segment_id = reader.read_positive_i64("wal-active-id")
    let active_start_lsn = reader.read_positive_i64("wal-active-start")
    let expected = reader.read_u32_bits()
    if reader.remaining() != 0 {
      raise TrailingData(offset=reader.position())
    }
    let actual = crc32(data[:data.length() - 4])
    if actual != expected {
      raise ChecksumMismatch(expected~, actual~)
    }
    let manifest = {
      generation,
      checkpoint_generation,
      checkpoint_lsn,
      sealed_segments,
      active_segment_id,
      active_start_lsn,
    }
    validate_wal_manifest(manifest)
    Ok(manifest)
  } catch {
    error => Err(error)
  }
}
