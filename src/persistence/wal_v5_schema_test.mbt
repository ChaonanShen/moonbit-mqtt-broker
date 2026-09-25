///|
test "C-T30 MQTT5 manifest and checkpoint require the same feature bit" {
  let manifest : WalManifestV5 = {
    generation: 1L,
    checkpoint_generation: 1L,
    checkpoint_lsn: 0L,
    sealed_segments: [],
    active_segment_id: 1L,
    active_start_lsn: 1L,
    required_features: feature_mqtt5_model,
  }
  let encoded_manifest = encode_wal_manifest_v5(manifest).unwrap()
  assert_eq(decode_wal_manifest_v5(encoded_manifest), Ok(manifest))
  assert_true(
    encode_wal_manifest_v5({ ..manifest, required_features: 8U }) is Err(_),
  )
  let checkpoint : WalCheckpointV5 = {
    generation: 1L,
    lsn: 0L,
    identities: [],
    required_features: feature_mqtt5_model,
    policy: None,
    snapshot: v5_empty_snapshot(),
  }
  let encoded_checkpoint = encode_wal_checkpoint_v5(checkpoint).unwrap()
  let limits = SnapshotDecodeLimits::new(
    @router.BrokerConfig::new(10, 10, 10).unwrap(),
    1024,
  ).unwrap()
  assert_eq(
    decode_wal_checkpoint_v5(encoded_checkpoint, limits),
    Ok(checkpoint),
  )
  assert_true(
    encode_wal_checkpoint_v5({
      ..checkpoint,
      required_features: feature_mqtt5_model | feature_policy_gate,
    })
    is Err(_),
  )
}
