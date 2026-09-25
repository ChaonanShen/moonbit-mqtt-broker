///|
async fn with_wal_writer_dir(
  name : String,
  body : async (String) -> Unit,
) -> Unit {
  let path = "_build/wal-writer-" + name
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  body(path)
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}

///|
fn wal_writer_empty_checkpoint() -> WalCheckpoint {
  {
    generation: 1L,
    lsn: 0L,
    identities: [],
    policy: None,
    snapshot: { version: 3, sessions: [], retained: [] },
  }
}

///|
async test "WAL writer reports each synced LSN without replacing a request" {
  with_wal_writer_dir("writer", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let store = WalStore::bootstrap(lock, wal_writer_empty_checkpoint()).unwrap()
    let writer = WalWriter::new(store)
    let mut wakes = 0
    @async.with_task_group() <| group => {
      let task = group.spawn(() => writer.run(() => wakes += 1))
      assert_true(
        writer.submit({
          writer_epoch: 1L,
          batch: {
            previous_lsn: 0L,
            transactions: [{ lsn: 1L, delta: b"first" }],
          },
        }),
      )
      let mut first : WalCompletion? = None
      for _ in 0..<1000 {
        first = writer.poll()
        if first is Some(_) {
          break
        }
        @async.sleep(1)
      }
      assert_eq(first, Some(Committed(1L, 1L, 1L)))
      assert_true(
        writer.submit({
          writer_epoch: 1L,
          batch: {
            previous_lsn: 1L,
            transactions: [{ lsn: 2L, delta: b"second" }],
          },
        }),
      )
      let mut second : WalCompletion? = None
      for _ in 0..<1000 {
        second = writer.poll()
        if second is Some(_) {
          break
        }
        @async.sleep(1)
      }
      assert_eq(second, Some(Committed(1L, 2L, 2L)))
      assert_true(wakes >= 2)
      writer.close_requests()
      task.wait()
      writer.close_store()
    }
  })
}

///|
async test "checkpoint encoding yields to a queued WAL batch before publication" {
  with_wal_writer_dir("preempt", path => {
    let config = PersistenceConfig::new(path).unwrap()
    let lock = SnapshotStore::open(config).unwrap()
    let store = WalStore::bootstrap(lock, wal_writer_empty_checkpoint()).unwrap()
    let empty = encode_durable_delta(@router.DurableDelta::empty()).unwrap()
    assert_eq(
      store.append_batch({
        previous_lsn: 0L,
        transactions: [{ lsn: 1L, delta: empty }],
      }),
      Ok(1L),
    )
    let writer = WalWriter::new(store)
    let large = Bytes::make(8388608, b'x')
    let checkpoint : WalCheckpoint = {
      generation: 2L,
      lsn: 1L,
      identities: [],
      policy: None,
      snapshot: {
        version: 3,
        sessions: [],
        retained: [{ topic: "large", payload: large, qos: 1 }],
      },
    }
    assert_true(writer.submit_checkpoint(checkpoint))
    @async.with_task_group() <| group => {
      let task = group.spawn(() => writer.run(() => ()))
      let mut active = false
      for _ in 0..<1000 {
        if writer.checkpoint_active() {
          active = true
          break
        }
        @async.sleep(1)
      }
      assert_true(active)
      assert_true(
        writer.submit({
          writer_epoch: 1L,
          batch: { previous_lsn: 1L, transactions: [{ lsn: 2L, delta: empty }] },
        }),
      )
      let mut preempted = false
      let mut committed = false
      for _ in 0..<1000 {
        match writer.poll() {
          Some(CheckpointFailed("preempted", false)) => preempted = true
          Some(Committed(1L, 2L, 2L)) => committed = true
          Some(_) => fail("unexpected WAL completion")
          None => @async.sleep(1)
        }
        if preempted && committed {
          break
        }
      }
      assert_true(preempted && committed)
      assert_false(writer.is_fenced())
      assert_eq(writer.checkpoint_lsn(), 0L)
      writer.close_requests()
      task.wait()
      writer.close_store()
    }
    let second = SnapshotStore::open(config).unwrap()
    let broker_config = @router.BrokerConfig::new(4, 16, 8).unwrap()
    let limits = SnapshotDecodeLimits::new(broker_config, 1024).unwrap()
    let (recovered, replay) = WalStore::recover_state(
      second, broker_config, limits,
    ).unwrap()
    assert_eq(replay.committed_lsn(), 2L)
    recovered.close()
  })
}
