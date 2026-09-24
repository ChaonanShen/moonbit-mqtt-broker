///|
async test "sliced checkpoint encoding equals the stable format and yields control" {
  let payload = Bytes::makei(2097152, index => (index % 251).to_byte())
  let checkpoint : WalCheckpoint = {
    generation: 2L,
    lsn: 7L,
    identities: [{ client_id: "large", generation: 3L }],
    policy: None,
    snapshot: {
      version: 3,
      sessions: [
        {
          client_id: "large",
          owner_principal: "anonymous",
          detached_at_ms: 0L,
          next_packet_id: 1,
          subscriptions: [{ filter: "large/#", qos: 1 }],
          inbound_qos2: [],
          inflight: [],
          pending: [{ topic: "large/value", payload, retain: false, qos: 1 }],
        },
      ],
      retained: [],
    },
  }
  let baseline = encode_wal_checkpoint(checkpoint).unwrap()
  let mut ticks = 0
  @async.with_task_group() <| group => {
    let ticker = group.spawn(() => {
      for _ in 0..<20 {
        @async.sleep(1)
        ticks += 1
      }
    })
    let sliced = encode_wal_checkpoint_sliced(checkpoint).unwrap()
    assert_eq(sliced, baseline)
    assert_true(ticks > 0)
    ticker.wait()
  }
}

///|
async test "sliced policy checkpoint equals direct encoding" {
  let digest : Array[Byte] = []
  for _ in 0..<32 {
    digest.push(5)
  }
  let checkpoint : WalCheckpoint = {
    generation: 1L,
    lsn: 0L,
    identities: [],
    policy: Some({
      sequence: 1L,
      fingerprint: Bytes::from_array(digest),
      reconcile_pending: false,
    }),
    snapshot: { version: 3, sessions: [], retained: [] },
  }
  assert_eq(
    encode_wal_checkpoint_sliced(checkpoint).unwrap(),
    encode_wal_checkpoint(checkpoint).unwrap(),
  )
}
