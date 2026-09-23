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
