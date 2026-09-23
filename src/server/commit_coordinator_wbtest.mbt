///|
async test "strict coordinator releases activation only after WAL completion" {
  let path = "_build/server-commit-coordinator"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let persistence_config = @persistence.PersistenceConfig::new(path).unwrap()
  let lock = @persistence.SnapshotStore::open(persistence_config).unwrap()
  let checkpoint : @persistence.WalCheckpoint = {
    generation: 1L,
    lsn: 0L,
    identities: [],
    snapshot: { version: 3, sessions: [], retained: [] },
  }
  let store = @persistence.WalStore::bootstrap(lock, checkpoint).unwrap()
  let writer = @persistence.WalWriter::new(store)
  let broker = @router.BrokerState::new(
    @router.BrokerConfig::new(4, 16, 4).unwrap(),
  )
  let coordinator = CommitCoordinator::new(
    writer,
    broker.resource_ledger(),
    33554432L,
    1048576,
    1L,
    0L,
  ).unwrap()
  let client = @session.ClientId::new("strict-client").unwrap()
  let activation = broker
    .prepare_durable_activation(
      client,
      @session.Persistent,
      @security.Principal::Anonymous,
      0L,
      1L,
    )
    .unwrap()
  assert_eq(coordinator.submit(Activation(activation), _ => []), Ok(1L))
  assert_eq(broker.session_count(), 0)
  let mut wakes = 0
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => wakes += 1))
    let mut completed = false
    for _ in 0..<1000 {
      match coordinator.poll() {
        CommitReleased(_, _) => {
          completed = true
          break
        }
        CommitFencedResult(reason) => fail("unexpected fence: " + reason)
        NoCommitCompletion => @async.sleep(1)
      }
    }
    assert_true(completed)
    assert_true(wakes > 0)
    assert_eq(coordinator.committed_lsn(), 1L)
    assert_eq(broker.session_count(), 1)
    assert_eq(broker.check_invariants(), Ok(()))
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}
