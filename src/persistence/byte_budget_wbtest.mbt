///|
test "binary writer rejects length before growing buffers" {
  let writer = BinaryWriter::new(max_bytes=4)
  let result = try {
    writer.write_raw(b"12345")
    Ok(())
  } catch {
    error => Err(error)
  }
  assert_true(result is Err(SnapshotTooLarge(..)))
  assert_eq(writer.bytes.length(), 0)
  writer.write_u32(7, "value")
  assert_eq(writer.bytes.length(), 4)
  assert_true(
    (try {
      writer.write_u8(0, "value")
      Ok(())
    } catch {
      error => Err(error)
    })
    is Err(SnapshotTooLarge(..)),
  )
  assert_eq(writer.bytes.length(), 4)
}

///|
test "decoder rejects aggregate session bytes before constructing oversized messages" {
  let snapshot = representative_snapshot()
  let encoded = encode_snapshot(snapshot).unwrap()
  let resources = @budget.Limits::default()
    .with_value("max_session_state_bytes", 1L)
    .unwrap()
  let broker = @router.BrokerConfig::new(100, 100, 100, resources~).unwrap()
  let limits = SnapshotDecodeLimits::new(broker, 1048576).unwrap()
  assert_true(decode_snapshot(encoded, limits) is Err(LimitExceeded(..)))
}

///|
test "decode workspace failure releases only its own lease and leaves input unchanged" {
  let encoded = encode_snapshot(representative_snapshot()).unwrap()
  let before = Bytes::from_array(encoded.to_array())
  let ledger = @budget.Ledger::new(500L, 0L).unwrap()
  let workspace = DecodeWorkspace::new(
    ledger.pool(Snapshot, 500L).unwrap(),
    100L,
  ).unwrap()
  let limits = SnapshotDecodeLimits::new(persistence_broker_config(), 1048576).unwrap()
  assert_true(
    decode_snapshot(encoded, limits, workspace~) is Err(LimitExceeded(..)),
  )
  workspace.release()
  assert_eq(ledger.occupied(), 0L)
  assert_eq(encoded, before)
}

///|
test "snapshot overwrite discard and active writer ownership are independent" {
  let ledger = @budget.Ledger::new(1000L, 0L).unwrap()
  let pool = ledger.pool(Snapshot, 1000L).unwrap()
  let sink = SnapshotSink::new()
  let old = pool.reserve(100L).unwrap()
  old.commit().unwrap()
  assert_true(
    sink.submit_accounted({ revision: 1L, snapshot: empty_snapshot() }, old),
  )
  let next = pool.reserve(200L).unwrap()
  next.commit().unwrap()
  assert_true(
    sink.submit_accounted({ revision: 2L, snapshot: empty_snapshot() }, next),
  )
  assert_eq(ledger.occupied(), 200L)
  let writing = sink.queue.try_get().unwrap()
  let queued = pool.reserve(50L).unwrap()
  queued.commit().unwrap()
  assert_true(
    sink.submit_accounted({ revision: 3L, snapshot: empty_snapshot() }, queued),
  )
  sink.discard()
  assert_eq(ledger.occupied(), 200L)
  writing.release()
  assert_eq(ledger.occupied(), 0L)
}

///|
async test "closed failing writer terminates degraded and releases active snapshot budget" {
  with_store_dir("budget-failed-close", path => {
    let store = SnapshotStore::open(store_config(path)).unwrap()
    store.fault = Some(TempOpen)
    let ledger = @budget.Ledger::new(1000L, 0L).unwrap()
    let ticket = ledger.pool(Snapshot, 1000L).unwrap().reserve(400L).unwrap()
    ticket.commit().unwrap()
    let sink = SnapshotSink::new()
    assert_true(
      sink.submit_accounted(
        { revision: 1L, snapshot: empty_snapshot() },
        ticket,
      ),
    )
    sink.close()
    let writer = SnapshotWriter::new(store, sink, 20L).unwrap()
    writer.run()
    assert_true(writer.is_degraded())
    assert_eq(writer.committed_revision(), -1L)
    assert_eq(ledger.occupied(), 0L)
    store.close()
  })
}

///|
async test "cancellation during failed snapshot retry releases active and queued leases" {
  with_store_dir("budget-cancel-retry", path => {
    let store = SnapshotStore::open(store_config(path)).unwrap()
    store.fault = Some(TempOpen)
    let ledger = @budget.Ledger::new(1000L, 0L).unwrap()
    let pool = ledger.pool(Snapshot, 1000L).unwrap()
    let first = pool.reserve(400L).unwrap()
    first.commit().unwrap()
    let sink = SnapshotSink::new()
    assert_true(
      sink.submit_accounted({ revision: 1L, snapshot: empty_snapshot() }, first),
    )
    let writer = SnapshotWriter::new(store, sink, 1000L).unwrap()
    @async.with_task_group() <| group => {
      let task = group.spawn(allow_failure=true, () => writer.run())
      for _ in 0..<1000 {
        if writer.is_degraded() {
          break
        }
        @async.sleep(1)
      }
      assert_true(writer.is_degraded())
      let second = pool.reserve(200L).unwrap()
      second.commit().unwrap()
      assert_true(
        sink.submit_accounted(
          { revision: 2L, snapshot: empty_snapshot() },
          second,
        ),
      )
      task.cancel()
      let finished = @async.with_timeout_opt(1000, () => {
        task.wait() catch {
          _ => ()
        }
        true
      })
      assert_eq(finished, Some(true))
      assert_eq(ledger.occupied(), 0L)
    }
    store.close()
  })
}
