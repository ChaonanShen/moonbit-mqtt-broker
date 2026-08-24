///|
fn persistence_broker_config() -> @router.BrokerConfig {
  @router.BrokerConfig::new(
    4,
    16,
    8,
    max_sessions=8,
    max_inflight_per_session=4,
    max_inflight_total=16,
    max_pending_qos1_per_session=8,
    max_pending_qos1_total=32,
  ).unwrap()
}

///|
fn empty_snapshot() -> @router.BrokerSnapshotV1 {
  { version: 2, sessions: [], retained: [] }
}

///|
fn representative_snapshot() -> @router.BrokerSnapshotV1 {
  {
    version: 2,
    sessions: [
      {
        client_id: "store-client",
        owner_principal: "user:store-owner",
        detached_at_ms: 0L,
        next_packet_id: 43,
        subscriptions: [{ filter: "state/#", qos: 1 }],
        inflight: [
          {
            packet_id: 42,
            message: {
              topic: "state/inflight",
              payload: b"inflight",
              retain: false,
            },
          },
        ],
        pending: [{ topic: "state/pending", payload: b"pending", retain: true }],
      },
    ],
    retained: [{ topic: "state/value", payload: b"value", qos: 1 }],
  }
}

///|
async fn with_store_dir(name : String, body : async (String) -> Unit) -> Unit {
  let path = "_build/m4-store-" + name
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  body(path)
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}

///|
fn store_config(
  path : String,
  max_bytes? : Int64 = 67108864L,
) -> PersistenceConfig {
  PersistenceConfig::new(path, max_snapshot_bytes=max_bytes).unwrap()
}

///|
async test "snapshot store creates data dir and loads missing main as empty" {
  with_store_dir("missing", path => {
    let store = SnapshotStore::open(store_config(path)).unwrap()
    assert_true(store.data_dir().has_prefix("/"))
    assert_true(@fs.exists(store.lock_path()))
    assert_false(@fs.exists(store.main_path()))
    let state = store.load_state(persistence_broker_config(), 1024).unwrap()
    assert_eq(state.export_snapshot(), empty_snapshot())
    store.close()
  })
}

///|
async test "snapshot store roundtrip restores exact broker state" {
  with_store_dir("roundtrip", path => {
    let config = store_config(path)
    let first = SnapshotStore::open(config).unwrap()
    let snapshot = representative_snapshot()
    let bytes = first.save(snapshot).unwrap()
    assert_true(bytes > 24)
    assert_false(@fs.exists(first.temp_path()))
    first.close()
    let second = SnapshotStore::open(config).unwrap()
    let restored = second
      .load_state(persistence_broker_config(), 1048576)
      .unwrap()
    assert_eq(restored.export_snapshot(), snapshot)
    second.close()
  })
}

///|
async test "stale temp never replaces committed snapshot" {
  with_store_dir("stale", path => {
    let config = store_config(path)
    let first = SnapshotStore::open(config).unwrap()
    ignore(first.save(empty_snapshot()).unwrap())
    let temp_path = first.temp_path()
    first.close()
    @fs.write_file(
      temp_path,
      encode_snapshot(representative_snapshot()).unwrap(),
      create_mode=CreateNew,
      permission=0o600,
    )
    let second = SnapshotStore::open(config).unwrap()
    assert_false(@fs.exists(temp_path))
    assert_eq(
      second
      .load_state(persistence_broker_config(), 1048576)
      .unwrap()
      .export_snapshot(),
      empty_snapshot(),
    )
    second.close()
  })

  with_store_dir("stale-only", path => {
    @fs.mkdir(path, permission=0o700, recursive=true)
    let temp = path + "/broker.snapshot.tmp"
    @fs.write_file(
      temp,
      encode_snapshot(representative_snapshot()).unwrap(),
      create_mode=CreateNew,
      permission=0o600,
    )
    let store = SnapshotStore::open(store_config(path)).unwrap()
    assert_false(@fs.exists(temp))
    assert_eq(
      store
      .load_state(persistence_broker_config(), 1048576)
      .unwrap()
      .export_snapshot(),
      empty_snapshot(),
    )
    store.close()
  })
}

///|
async test "second broker cannot acquire snapshot lock" {
  with_store_dir("lock", path => {
    let config = store_config(path)
    let first = SnapshotStore::open(config).unwrap()
    assert_true(SnapshotStore::open(config) is Err(LockConflict(_)))
    first.close()
    let second = SnapshotStore::open(config).unwrap()
    second.close()
  })
}

///|
async test "atomic save preserves previous snapshot on failure" {
  with_store_dir("atomic", path => {
    let store = SnapshotStore::open(store_config(path)).unwrap()
    let previous = empty_snapshot()
    let replacement = representative_snapshot()
    ignore(store.save(previous).unwrap())
    let main_before = @fs.read_file(store.main_path()).binary()
    for fault in [TempOpen, TempWrite, TempSync, TempClose, Rename] {
      store.fault = Some(fault)
      assert_true(store.save(replacement) is Err(_))
      assert_eq(@fs.read_file(store.main_path()).binary(), main_before)
      assert_false(@fs.exists(store.temp_path()))
      assert_eq(
        store
        .load_state(persistence_broker_config(), 1048576)
        .unwrap()
        .export_snapshot(),
        previous,
      )
    }
    store.fault = None
    ignore(store.save(replacement).unwrap())
    assert_eq(
      store
      .load_state(persistence_broker_config(), 1048576)
      .unwrap()
      .export_snapshot(),
      replacement,
    )
    store.close()
  })
}

///|
async test "directory sync failure leaves a complete new main" {
  with_store_dir("uncertain", path => {
    let store = SnapshotStore::open(store_config(path)).unwrap()
    ignore(store.save(empty_snapshot()).unwrap())
    store.fault = Some(DirectorySync)
    assert_true(
      store.save(representative_snapshot()) is Err(DurabilityUncertain(_)),
    )
    assert_eq(
      store
      .load_state(persistence_broker_config(), 1048576)
      .unwrap()
      .export_snapshot(),
      representative_snapshot(),
    )
    store.close()
  })
}

///|
async test "snapshot store rejects corrupt oversize symlink and nonregular main" {
  with_store_dir("corrupt", path => {
    let store = SnapshotStore::open(store_config(path)).unwrap()
    @fs.write_file(
      store.main_path(),
      b"corrupt",
      create_mode=CreateNew,
      permission=0o600,
    )
    assert_true(store.load_state(persistence_broker_config(), 1024) is Err(_))
    store.close()
  })
  with_store_dir("oversize", path => {
    let store = SnapshotStore::open(store_config(path, max_bytes=36L)).unwrap()
    @fs.write_file(
      store.main_path(),
      Bytes::make(37, b'\x00'),
      create_mode=CreateNew,
      permission=0o600,
    )
    assert_true(
      store.load_state(persistence_broker_config(), 1024)
      is Err(SnapshotTooLarge(..)),
    )
    store.close()
  })
  with_store_dir("symlink", path => {
    let store = SnapshotStore::open(store_config(path)).unwrap()
    let target = store.data_dir() + "/target"
    @fs.write_file(
      target,
      encode_snapshot(empty_snapshot()).unwrap(),
      create_mode=CreateNew,
      permission=0o600,
    )
    @fs.symlink(target="target", store.main_path())
    assert_true(store.load_state(persistence_broker_config(), 1024) is Err(_))
    store.close()
  })
  with_store_dir("directory-main", path => {
    let store = SnapshotStore::open(store_config(path)).unwrap()
    @fs.mkdir(store.main_path(), permission=0o700)
    assert_true(store.load_state(persistence_broker_config(), 1024) is Err(_))
    store.close()
  })
}

///|
async test "snapshot import rejects duplicate domain keys atomically" {
  with_store_dir("duplicates", path => {
    let duplicate : @router.SnapshotSessionV1 = {
      client_id: "same",
      owner_principal: "legacy-anonymous",
      detached_at_ms: 0L,
      next_packet_id: 1,
      subscriptions: [],
      inflight: [],
      pending: [],
    }
    let store = SnapshotStore::open(store_config(path)).unwrap()
    ignore(
      store
      .save({ version: 2, sessions: [duplicate, duplicate], retained: [] })
      .unwrap(),
    )
    assert_true(
      store.load_state(persistence_broker_config(), 1024)
      is Err(SnapshotImport(_)),
    )
    store.close()
  })
}

///|
test "snapshot sink capacity one overwrites with latest revision" {
  let sink = SnapshotSink::new()
  assert_true(sink.submit({ revision: 1L, snapshot: empty_snapshot() }))
  assert_true(
    sink.submit({ revision: 2L, snapshot: representative_snapshot() }),
  )
  assert_true(sink.submit({ revision: 3L, snapshot: empty_snapshot() }))
  assert_eq(sink.queue.try_get().unwrap().revision, 3L)
  sink.close()
  assert_false(sink.submit({ revision: 4L, snapshot: empty_snapshot() }))
}

///|
async test "snapshot writer commits only the latest queued revision" {
  with_store_dir("writer-latest", path => {
    let store = SnapshotStore::open(store_config(path)).unwrap()
    let sink = SnapshotSink::new()
    let writer = SnapshotWriter::new(store, sink, 20L).unwrap()
    assert_true(sink.submit({ revision: 1L, snapshot: empty_snapshot() }))
    assert_true(
      sink.submit({ revision: 2L, snapshot: representative_snapshot() }),
    )
    sink.close()
    writer.run()
    assert_eq(writer.committed_revision(), 2L)
    assert_eq(writer.attempt_count(), 1)
    assert_eq(
      store
      .load_state(persistence_broker_config(), 1048576)
      .unwrap()
      .export_snapshot(),
      representative_snapshot(),
    )
    store.close()
  })
}

///|
async test "failed save retries latest snapshot without blocking router" {
  with_store_dir("writer-retry", path => {
    let store = SnapshotStore::open(store_config(path)).unwrap()
    store.fault = Some(TempOpen)
    let sink = SnapshotSink::new()
    let writer = SnapshotWriter::new(store, sink, 20L).unwrap()
    assert_true(sink.submit({ revision: 1L, snapshot: empty_snapshot() }))
    @async.with_task_group() <| group => {
      let task = group.spawn(() => writer.run())
      for _ in 0..<100 {
        if writer.is_degraded() {
          break
        }
        @async.sleep(1)
      }
      assert_true(writer.is_degraded())
      // Submission remains synchronous while the writer is in its retry delay.
      assert_true(
        sink.submit({ revision: 2L, snapshot: representative_snapshot() }),
      )
      store.fault = None
      for _ in 0..<100 {
        if writer.committed_revision() == 2L {
          break
        }
        @async.sleep(2)
      }
      assert_eq(writer.committed_revision(), 2L)
      assert_false(writer.is_degraded())
      sink.close()
      task.wait()
    }
    assert_eq(
      store
      .load_state(persistence_broker_config(), 1048576)
      .unwrap()
      .export_snapshot(),
      representative_snapshot(),
    )
    store.close()
  })
}
