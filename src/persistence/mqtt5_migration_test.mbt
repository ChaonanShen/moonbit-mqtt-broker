///|
test "C-T31 V3 migration preserves literal share filter and QoS exchange" {
  let old : @router.BrokerSnapshotV3 = {
    version: 3,
    sessions: [
      {
        client_id: "legacy",
        owner_principal: "anonymous",
        detached_at_ms: 42L,
        next_packet_id: 9,
        subscriptions: [{ filter: "$share/workers/jobs/#", qos: 1 }],
        inbound_qos2: [11],
        inflight: [{ packet_id: 7, phase: 3, message: None }],
        pending: [
          { topic: "jobs/a", payload: b"queued", retain: false, qos: 1 },
        ],
      },
    ],
    retained: [{ topic: "state/a", payload: b"saved", qos: 1 }],
  }
  let limits = SnapshotDecodeLimits::new(
    @router.BrokerConfig::new(10, 10, 10).unwrap(),
    1024,
  ).unwrap()
  let old_bytes = encode_snapshot(old).unwrap()
  let decoded_old = decode_snapshot(old_bytes, limits).unwrap()
  let migrated = convert_v3_snapshot_to_v5(decoded_old).unwrap()
  assert_eq(migrated.sessions[0].subscriptions[0].kind, 2)
  assert_eq(
    migrated.sessions[0].subscriptions[0].wire_filter,
    "$share/workers/jobs/#",
  )
  assert_eq(migrated.sessions[0].inflight[0].packet_id, 7)
  assert_eq(migrated.sessions[0].inflight[0].phase, 3)
  assert_true(migrated.sessions[0].inflight[0].started)
  assert_eq(migrated.sessions[0].pending[0].message.payload, b"queued")
  assert_eq(migrated.retained[0].message.payload, b"saved")
  assert_eq(migrated.sessions[0].retention, @session.LegacyBrokerPolicy)
  let new_bytes = encode_snapshot_v5(migrated).unwrap()
  assert_eq(decode_snapshot_v5(new_bytes, limits), Ok(migrated))
}
