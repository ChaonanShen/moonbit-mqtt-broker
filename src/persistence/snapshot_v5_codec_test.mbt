///|
fn v5_test_hex_digit(char : Char) -> Int {
  match char {
    '0'..='9' => char.to_int() - '0'.to_int()
    'a'..='f' => char.to_int() - 'a'.to_int() + 10
    _ => abort("invalid golden hex")
  }
}

///|
fn v5_test_hex(value : String) -> Bytes {
  let chars = value.to_array()
  let bytes : Array[Byte] = []
  for index in 0..<(chars.length() / 2) {
    bytes.push(
      ((v5_test_hex_digit(chars[index * 2]) << 4) |
      v5_test_hex_digit(chars[index * 2 + 1])).to_byte(),
    )
  }
  Bytes::from_array(bytes)
}

///|
fn v5_empty_snapshot() -> @router.BrokerSnapshotV5 {
  {
    clock_floor_wall_ms: 0L,
    next_session_incarnation: 1L,
    next_subscription_identity: 1L,
    next_delivery_id: 1L,
    next_group_id: 1L,
    next_will_id: 1L,
    next_retained_revision: 1L,
    groups: [],
    sessions: [],
    retained: [],
    wills: [],
  }
}

///|
test "C-T30 empty MQTT5 snapshot has fixed independent golden bytes" {
  let snapshot = v5_empty_snapshot()
  let encoded = encode_snapshot_v5(snapshot).unwrap()
  let golden = v5_test_hex(
    "4d424d515454303100050000000000000000004c151d274500000005000000000000000000000000000000010000000000000001000000000000000100000000000000010000000000000001000000000000000100000000000000000000000000000000",
  )
  assert_eq(encoded, golden)
  let limits = SnapshotDecodeLimits::new(
    @router.BrokerConfig::new(10, 10, 10).unwrap(),
    1024,
  ).unwrap()
  assert_eq(decode_snapshot_v5(golden, limits), Ok(snapshot))
  let bad = Bytes::from_array(encoded.to_array())
  let bytes = bad.to_array()
  bytes[99] = 1
  assert_true(
    decode_snapshot_v5(Bytes::from_array(bytes), limits)
    is Err(ChecksumMismatch(..)),
  )
}

///|
test "C-T30 MQTT5 session metadata survives snapshot codec" {
  let props : @router.SnapshotApplicationPropertiesV5 = {
    payload_format: Some(1),
    content_type: Some("text/plain"),
    response_topic: Some("reply/a"),
    correlation_data: Some(b"\x00\xff"),
    user_properties: [("k", "v1"), ("k", "v2")],
  }
  let message : @router.SnapshotMessageV5 = {
    topic: "data/a",
    payload: b"value",
    qos: 1,
    retain: false,
    publisher_client_id: Some("sender"),
    properties: props,
    expiry_clock: Some({
      sample_wall_ms: 1000L,
      remaining_ms: 5000L,
      deadline_wall_ms: 6000L,
    }),
  }
  let snapshot : @router.BrokerSnapshotV5 = {
    ..v5_empty_snapshot(),
    next_session_incarnation: 2L,
    next_subscription_identity: 2L,
    next_delivery_id: 2L,
    sessions: [
      {
        client_id: "client",
        owner_principal: "anonymous",
        incarnation: 1L,
        lifecycle_version: 1L,
        state_revision: 1L,
        last_protocol: 5,
        retention: @session.FiniteV5(30U),
        attached_at_capture: false,
        detached_at_wall_ms: Some(1000L),
        session_expiry_clock: Some({
          sample_wall_ms: 1000L,
          remaining_ms: 30000L,
          deadline_wall_ms: 31000L,
        }),
        next_packet_id: 1,
        subscriptions: [
          {
            identity: 1L,
            kind: 0,
            wire_filter: "data/+",
            group_id: None,
            group_incarnation: None,
            inner_filter: None,
            qos: 1,
            no_local: true,
            retain_as_published: true,
            retain_handling: 1,
            subscription_identifier: Some(7U),
          },
        ],
        inbound_qos2: [],
        inflight: [],
        pending: [
          {
            delivery_id: 1L,
            message,
            shared_origin: None,
            subscription_identifiers: [7U],
          },
        ],
      },
    ],
  }
  let limits = SnapshotDecodeLimits::new(
    @router.BrokerConfig::new(10, 10, 10).unwrap(),
    1024,
  ).unwrap()
  let encoded = encode_snapshot_v5(snapshot).unwrap()
  assert_eq(decode_snapshot_v5(encoded, limits), Ok(snapshot))
  assert_true(
    encode_snapshot_v5({ ..snapshot, next_delivery_id: 1L }) is Err(_),
  )
}
