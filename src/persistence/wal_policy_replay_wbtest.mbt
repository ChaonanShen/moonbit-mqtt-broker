///|
test "policy WAL recovery rejects an invalid transition order" {
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let limits = SnapshotDecodeLimits::new(broker_config, 1024).unwrap()
  let digest : Array[Byte] = []
  for _ in 0..<32 {
    digest.push(1)
  }
  let fingerprint = Bytes::from_array(digest)
  let checkpoint : WalCheckpoint = {
    generation: 1L,
    lsn: 0L,
    identities: [],
    policy: None,
    snapshot: { version: 3, sessions: [], retained: [] },
  }
  let record = encode_wal_policy_record({
    transition: PolicyReconciled,
    sequence: 1L,
    fingerprint,
  }).unwrap()
  let recovery : WalRecovery = {
    checkpoint,
    batches: [{ previous_lsn: 0L, transactions: [{ lsn: 1L, delta: record }] }],
    committed_lsn: 1L,
    recovered_tail: false,
    policy_required: true,
  }
  assert_true(recovery.restore_state(broker_config, limits) is Err(_))
  let no_capability : WalRecovery = { ..recovery, policy_required: false }
  assert_true(no_capability.restore_state(broker_config, limits) is Err(_))
}
