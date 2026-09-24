///|
fn wal_checkpoint_limits() -> SnapshotDecodeLimits {
  SnapshotDecodeLimits::new(
    @router.BrokerConfig::new(4, 16, 8, max_sessions=8).unwrap(),
    1024,
  ).unwrap()
}

///|
fn wal_checkpoint_fixture() -> WalCheckpoint {
  {
    generation: 2L,
    lsn: 10L,
    identities: [{ client_id: "client-a", generation: 7L }],
    policy: None,
    snapshot: {
      version: 3,
      sessions: [
        {
          client_id: "client-a",
          owner_principal: "anonymous",
          detached_at_ms: 0L,
          next_packet_id: 1,
          subscriptions: [],
          inbound_qos2: [],
          inflight: [],
          pending: [],
        },
      ],
      retained: [],
    },
  }
}

///|
test "WAL checkpoint preserves session generations alongside Disk V3 state" {
  let checkpoint = wal_checkpoint_fixture()
  let first = encode_wal_checkpoint(checkpoint).unwrap()
  assert_eq(first, encode_wal_checkpoint(checkpoint).unwrap())
  assert_eq(
    decode_wal_checkpoint(first, wal_checkpoint_limits()),
    Ok(checkpoint),
  )
  let changed = first.to_array()
  changed[20] = changed[20] ^ 1
  assert_true(
    decode_wal_checkpoint(Bytes::from_array(changed), wal_checkpoint_limits())
    is Err(ChecksumMismatch(..)),
  )
}

///|
test "WAL checkpoint rejects missing identity rather than inventing one" {
  let fixture = wal_checkpoint_fixture()
  let invalid : WalCheckpoint = { ..fixture, identities: [] }
  assert_true(encode_wal_checkpoint(invalid) is Err(InvalidValue(..)))
}

///|
test "WAL checkpoint v2 keeps policy gate and unfinished reconcile" {
  let digest : Array[Byte] = []
  for _ in 0..<32 {
    digest.push(9)
  }
  let policy : WalPolicyState = {
    sequence: 4L,
    fingerprint: Bytes::from_array(digest),
    reconcile_pending: true,
  }
  let checkpoint : WalCheckpoint = {
    ..wal_checkpoint_fixture(),
    policy: Some(policy),
  }
  let bytes = encode_wal_checkpoint(checkpoint).unwrap()
  assert_true(bytes.length() > 40)
  assert_eq(
    decode_wal_checkpoint(bytes, wal_checkpoint_limits()),
    Ok(checkpoint),
  )
  assert_true(
    encode_wal_checkpoint({
      ..checkpoint,
      policy: Some({ ..policy, fingerprint: b"short" }),
    })
    is Err(_),
  )
}
