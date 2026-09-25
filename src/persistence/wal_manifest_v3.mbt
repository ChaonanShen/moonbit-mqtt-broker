///|
pub(all) struct WalManifestV5 {
  generation : Int64
  checkpoint_generation : Int64
  checkpoint_lsn : Int64
  sealed_segments : Array[WalSealedSegment]
  active_segment_id : Int64
  active_start_lsn : Int64
  required_features : UInt
} derive(Eq, Debug)

///|
fn validate_wal_manifest_v5(
  value : WalManifestV5,
) -> Unit raise PersistenceError {
  if !supported_mqtt5_features(value.required_features) ||
    (value.required_features & feature_mqtt5_model) == 0U {
    raise wal_corrupt("manifest-required-features", 12)
  }
  validate_wal_manifest({
    generation: value.generation,
    checkpoint_generation: value.checkpoint_generation,
    checkpoint_lsn: value.checkpoint_lsn,
    sealed_segments: value.sealed_segments,
    active_segment_id: value.active_segment_id,
    active_start_lsn: value.active_start_lsn,
    policy_required: (value.required_features & feature_policy_gate) != 0U,
  })
}

///|
pub fn encode_wal_manifest_v5(
  value : WalManifestV5,
) -> Result[Bytes, PersistenceError] {
  try {
    validate_wal_manifest_v5(value)
    let writer = BinaryWriter::new(max_bytes=32768)
    writer.write_raw(wal_manifest_magic)
    writer.write_u16(mqtt5_manifest_version, "manifest-version")
    writer.write_u16(mqtt5_wal_logical_schema, "manifest-logical-schema")
    writer.write_u32_bits(value.required_features)
    writer.write_positive_i64(value.generation, "manifest-generation")
    writer.write_positive_i64(
      value.checkpoint_generation,
      "checkpoint-generation",
    )
    writer.write_positive_i64(value.checkpoint_lsn, "checkpoint-lsn")
    writer.write_u32(value.sealed_segments.length(), "sealed-count")
    for segment in value.sealed_segments {
      writer.write_positive_i64(segment.segment_id, "segment-id")
      writer.write_positive_i64(segment.start_lsn, "segment-start")
      writer.write_positive_i64(segment.end_lsn, "segment-end")
    }
    writer.write_positive_i64(value.active_segment_id, "active-id")
    writer.write_positive_i64(value.active_start_lsn, "active-start")
    let prefix = writer.finish()
    writer.write_u32_bits(crc32(prefix))
    Ok(writer.finish())
  } catch {
    error => Err(error)
  }
}

///|
pub fn decode_wal_manifest_v5(
  data : Bytes,
) -> Result[WalManifestV5, PersistenceError] {
  try {
    if data.length() > 32768 {
      raise LimitExceeded(
        resource="manifest-bytes",
        actual=data.length().to_int64(),
        limit=32768L,
      )
    }
    let reader = BinaryReader::new(data)
    if reader.read_raw(8) != wal_manifest_magic {
      raise InvalidMagic
    }
    let version = reader.read_u16()
    if version != mqtt5_manifest_version {
      raise UnsupportedEnvelopeVersion(version)
    }
    if reader.read_u16() != mqtt5_wal_logical_schema {
      raise wal_corrupt("manifest-logical-schema", 10)
    }
    let required_features = reader.read_u32_bits()
    let generation = reader.read_positive_i64("manifest-generation")
    let checkpoint_generation = reader.read_positive_i64(
      "checkpoint-generation",
    )
    let checkpoint_lsn = reader.read_positive_i64("checkpoint-lsn")
    let count = checked_count(reader, "sealed-count", 512)
    let sealed_segments : Array[WalSealedSegment] = []
    for _ in 0..<count {
      sealed_segments.push({
        segment_id: reader.read_positive_i64("segment-id"),
        start_lsn: reader.read_positive_i64("segment-start"),
        end_lsn: reader.read_positive_i64("segment-end"),
      })
    }
    let active_segment_id = reader.read_positive_i64("active-id")
    let active_start_lsn = reader.read_positive_i64("active-start")
    if reader.remaining() != 4 {
      raise TrailingData(offset=reader.position())
    }
    let expected = reader.read_u32_bits()
    let actual = crc32(data[:data.length() - 4])
    if expected != actual {
      raise ChecksumMismatch(expected~, actual~)
    }
    let value : WalManifestV5 = {
      generation,
      checkpoint_generation,
      checkpoint_lsn,
      sealed_segments,
      active_segment_id,
      active_start_lsn,
      required_features,
    }
    validate_wal_manifest_v5(value)
    Ok(value)
  } catch {
    error => Err(error)
  }
}
