///|
fn codec_limits(
  max_payload? : Int = 1048576,
  max_snapshot? : Int = 67108864,
) -> SnapshotDecodeLimits {
  SnapshotDecodeLimits::new(
    persistence_broker_config(),
    max_payload,
    max_snapshot_bytes=max_snapshot,
  ).unwrap()
}

///|
fn empty_snapshot() -> @router.BrokerSnapshotV1 {
  { version: 1, sessions: [], retained: [] }
}

///|
fn representative_snapshot() -> @router.BrokerSnapshotV1 {
  {
    version: 1,
    sessions: [
      {
        client_id: "client-月",
        next_packet_id: 43,
        subscriptions: [
          { filter: "telemetry/+", qos: 0 },
          { filter: "状态/#", qos: 1 },
        ],
        inflight: [
          {
            packet_id: 42,
            message: {
              topic: "状态/online",
              payload: Bytes::makei(256, index => index.to_byte()),
              retain: false,
            },
          },
        ],
        pending: [{ topic: "telemetry/2", payload: b"pending", retain: true }],
      },
    ],
    retained: [{ topic: "retained/value", payload: b"\x00\xffvalue", qos: 1 }],
  }
}

///|
fn replace_byte(data : Bytes, offset : Int, value : Byte) -> Bytes {
  let bytes = data.to_array()
  bytes[offset] = value
  Bytes::from_array(bytes)
}

///|
fn refresh_payload_crc(data : Bytes) -> Bytes {
  let bytes = data.to_array()
  let payload = Bytes::from_array(bytes[24:].to_owned())
  let checksum = crc32(payload)
  bytes[20] = (checksum >> 24).to_byte()
  bytes[21] = (checksum >> 16).to_byte()
  bytes[22] = (checksum >> 8).to_byte()
  bytes[23] = checksum.to_byte()
  Bytes::from_array(bytes)
}

///|
test "snapshot codec is deterministic and checksum protected" {
  let snapshot = representative_snapshot()
  let first = encode_snapshot(snapshot).unwrap()
  let second = encode_snapshot(snapshot).unwrap()
  assert_eq(first, second)
  assert_eq(decode_snapshot(first, codec_limits()), Ok(snapshot))
  let corrupt = replace_byte(
    first,
    first.length() - 1,
    first[first.length() - 1] ^ 1,
  )
  assert_true(
    decode_snapshot(corrupt, codec_limits()) is Err(ChecksumMismatch(..)),
  )
}

///|
test "disk v1 empty snapshot golden bytes are stable" {
  let expected = Bytes::from_array([
    0x4d, 0x42, 0x4d, 0x51, 0x54, 0x54, 0x30, 0x31, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x6c, 0xae, 0xd2, 0x2c, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ])
  assert_eq(encode_snapshot(empty_snapshot()), Ok(expected))
  assert_eq(decode_snapshot(expected, codec_limits()), Ok(empty_snapshot()))
}

///|
test "snapshot decoder rejects truncation before allocation" {
  let encoded = encode_snapshot(representative_snapshot()).unwrap()
  let raw = encoded.to_array()
  for end in 0..<encoded.length() {
    let truncated = Bytes::from_array(raw[:end].to_owned())
    assert_true(decode_snapshot(truncated, codec_limits()) is Err(_))
  }
  let huge_count = encoded.to_array()
  huge_count[28] = 0xff
  huge_count[29] = 0xff
  huge_count[30] = 0xff
  huge_count[31] = 0xff
  let huge_count = refresh_payload_crc(Bytes::from_array(huge_count))
  assert_true(
    decode_snapshot(huge_count, codec_limits()) is Err(LimitExceeded(..)),
  )
}

///|
test "snapshot envelope rejects every structural corruption class" {
  let encoded = encode_snapshot(empty_snapshot()).unwrap()
  assert_true(
    decode_snapshot(replace_byte(encoded, 0, 0), codec_limits())
    is Err(InvalidMagic),
  )
  assert_true(
    decode_snapshot(replace_byte(encoded, 9, 2), codec_limits())
    is Err(UnsupportedEnvelopeVersion(2)),
  )
  assert_true(
    decode_snapshot(replace_byte(encoded, 11, 1), codec_limits())
    is Err(UnknownFlags(1)),
  )
  assert_true(
    decode_snapshot(replace_byte(encoded, 19, 11), codec_limits())
    is Err(LengthMismatch(..)),
  )
  assert_true(
    decode_snapshot(replace_byte(encoded, 20, encoded[20] ^ 1), codec_limits())
    is Err(ChecksumMismatch(..)),
  )
  let trailing = encoded.to_array()
  trailing.push(0)
  assert_true(
    decode_snapshot(Bytes::from_array(trailing), codec_limits())
    is Err(LengthMismatch(..)),
  )
}

///|
test "snapshot decoder rejects invalid utf8 bool qos and packet ids" {
  let invalid_qos : @router.BrokerSnapshotV1 = {
    version: 1,
    sessions: [],
    retained: [{ topic: "valid", payload: b"x", qos: 2 }],
  }
  assert_true(encode_snapshot(invalid_qos) is Err(InvalidValue(..)))
  let invalid_packet : @router.BrokerSnapshotV1 = {
    version: 1,
    sessions: [
      {
        client_id: "c",
        next_packet_id: 0,
        subscriptions: [],
        inflight: [],
        pending: [],
      },
    ],
    retained: [],
  }
  assert_true(encode_snapshot(invalid_packet) is Err(InvalidValue(..)))

  let encoded = encode_snapshot({
    version: 1,
    sessions: [],
    retained: [{ topic: "a", payload: b"x", qos: 1 }],
  }).unwrap()
  // payload: version(4), sessions(4), retained count(4), string length(4), byte.
  let invalid_utf8 = refresh_payload_crc(replace_byte(encoded, 40, 0xff))
  assert_true(
    decode_snapshot(invalid_utf8, codec_limits()) is Err(InvalidUtf8(..)),
  )
  let invalid_qos = refresh_payload_crc(replace_byte(encoded, 46, 2))
  assert_true(
    decode_snapshot(invalid_qos, codec_limits()) is Err(InvalidValue(..)),
  )
}

///|
test "snapshot codec enforces payload and final file size limits" {
  let snapshot = representative_snapshot()
  let encoded = encode_snapshot(snapshot).unwrap()
  assert_eq(
    encode_snapshot(snapshot, max_snapshot_bytes=encoded.length()),
    Ok(encoded),
  )
  assert_true(
    encode_snapshot(snapshot, max_snapshot_bytes=encoded.length() - 1)
    is Err(SnapshotTooLarge(..)),
  )
  assert_true(
    decode_snapshot(encoded, codec_limits(max_payload=255))
    is Err(LimitExceeded(..)),
  )
  assert_true(
    decode_snapshot(encoded, codec_limits(max_snapshot=encoded.length() - 1))
    is Err(SnapshotTooLarge(..)),
  )
}

///|
test "snapshot model version remains an import-layer decision" {
  let encoded = encode_snapshot({ ..empty_snapshot(), version: 2 }).unwrap()
  let decoded = decode_snapshot(encoded, codec_limits()).unwrap()
  assert_eq(decoded.version, 2)
  assert_true(
    @router.BrokerState::from_snapshot(persistence_broker_config(), decoded)
    is Err(@router.SnapshotError::UnsupportedVersion(2)),
  )
}
