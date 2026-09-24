///|
async test "strict group commit fsyncs two disjoint persistent publications as one batch" {
  let path = "_build/server-strict-group-commit"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let config = @router.BrokerConfig::new(4, 16, 0).unwrap()
  let broker = @router.BrokerState::new(config)
  let first = @session.ClientId::new("first").unwrap()
  let second = @session.ClientId::new("second").unwrap()
  for pair in [(first, "a"), (second, "b")] {
    let (client_id, filter_name) = pair
    ignore(
      broker.apply(
        @router.CreateSessionWith({
          client_id,
          mode: @session.Persistent,
          attached: true,
        }),
      ),
    )
    ignore(
      broker.apply(
        @router.Subscribe({
          client_id,
          entries: [
            {
              filter: @topic.TopicFilter::new(filter_name).unwrap(),
              qos: @session.QoS1,
            },
          ],
        }),
      ),
    )
  }
  let snapshot = broker.export_snapshot()
  let lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let writer = @persistence.WalWriter::new(
    @persistence.WalStore::bootstrap(lock, {
      generation: 1L,
      lsn: 0L,
      identities: snapshot.sessions.map(item => {
        client_id: item.client_id,
        generation: if item.client_id == "first" {
          1L
        } else {
          2L
        },
      }),
      policy: None,
      snapshot,
    }).unwrap(),
  )
  let coordinator = CommitCoordinator::new(
    writer,
    broker.resource_ledger(),
    33554432L,
    1048576,
    1L,
    0L,
    broker~,
  ).unwrap()
  let generations = Map([(first, 1L), (second, 2L)])
  let first_plan = broker
    .prepare_durable_publish(
      {
        origin: @router.Internal,
        topic: @topic.TopicName::new("a").unwrap(),
        payload: b"one",
        qos: @session.QoS1,
        retain: false,
      },
      generations,
    )
    .unwrap()
  let second_plan = broker
    .prepare_durable_publish(
      {
        origin: @router.Internal,
        topic: @topic.TopicName::new("b").unwrap(),
        payload: b"two",
        qos: @session.QoS1,
        retain: false,
      },
      generations,
    )
    .unwrap()
  assert_eq(
    coordinator.submit(
      Publish(first_plan),
      _ => [],
      connection_id=ConnectionId::new(1L),
    ),
    Ok(1L),
  )
  assert_eq(
    coordinator.submit(
      Publish(second_plan),
      _ => [],
      connection_id=ConnectionId::new(2L),
    ),
    Ok(2L),
  )
  assert_true(coordinator.is_collecting())
  assert_eq(broker.inflight_count(), 0)
  assert_true(coordinator.flush())
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    let mut completed = false
    for _ in 0..<1000 {
      match coordinator.poll() {
        CommitReleased(_, deltas, connections) => {
          assert_eq(deltas.length(), 2)
          assert_eq(connections, [
            Some(ConnectionId::new(1L)),
            Some(ConnectionId::new(2L)),
          ])
          completed = true
          break
        }
        CommitFencedResult(reason) => fail("batch fenced: " + reason)
        NoCommitCompletion => @async.sleep(1)
        _ => fail("unexpected checkpoint completion")
      }
    }
    assert_true(completed)
    assert_eq(broker.inflight_count(), 2)
    assert_eq(broker.check_invariants(), Ok(()))
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  let second_lock = @persistence.SnapshotStore::open(
    @persistence.PersistenceConfig::new(path).unwrap(),
  ).unwrap()
  let limits = @persistence.SnapshotDecodeLimits::new(config, 1024).unwrap()
  let (recovered, replay) = @persistence.WalStore::recover(second_lock, limits).unwrap()
  assert_eq(replay.batches().length(), 1)
  assert_eq(replay.batches()[0].transactions.length(), 2)
  assert_eq(
    replay.restore_state(config, limits).unwrap().state().inflight_count(),
    2,
  )
  recovered.close()
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}
