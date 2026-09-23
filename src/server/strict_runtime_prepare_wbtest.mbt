///|
async test "strict QoS1 ACK and fanout wait for WAL completion" {
  let path = "_build/server-strict-publish"
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  let broker_config = @router.BrokerConfig::new(8, 32, 8).unwrap()
  let config = ServerConfig::new(8, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let rt = BrokerRuntime::new(config, @router.BrokerState::new(broker_config))
  let subscriber = ConnectionId::new(11L)
  let publisher = ConnectionId::new(12L)
  for item in [(subscriber, "subscriber"), (publisher, "publisher")] {
    let (connection_id, name) = item
    ignore(rt.apply(TransportOpened({ connection_id, accepted_at_ms: 0L })))
    ignore(
      rt.apply(
        PacketReceived({
          connection_id,
          received_at_ms: 1L,
          packet: Connect({
            client_id: name,
            username: None,
            password: None,
            keep_alive: 10,
            clean_session: false,
            will: None,
          }),
        }),
      ),
    )
  }
  ignore(
    rt.apply(
      PacketReceived({
        connection_id: subscriber,
        received_at_ms: 2L,
        packet: Subscribe({
          packet_id: @protocol.PacketId::new(1).unwrap(),
          subscriptions: [{ topic_filter: "topic", requested_qos: QoS1 }],
        }),
      }),
    ),
  )
  let snapshot = rt.broker_state().export_snapshot()
  let checkpoint : @persistence.WalCheckpoint = {
    generation: 1L,
    lsn: 0L,
    identities: snapshot.sessions.map(item => {
      client_id: item.client_id,
      generation: if item.client_id == "publisher" {
        1L
      } else {
        2L
      },
    }),
    snapshot,
  }
  let persistence_config = @persistence.PersistenceConfig::new(path).unwrap()
  let lock = @persistence.SnapshotStore::open(persistence_config).unwrap()
  let store = @persistence.WalStore::bootstrap(lock, checkpoint).unwrap()
  let writer = @persistence.WalWriter::new(store)
  let coordinator = CommitCoordinator::new(
    writer,
    rt.broker_state().resource_ledger(),
    33554432L,
    1048576,
    1L,
    0L,
  ).unwrap()
  let generations = Map([
    (@session.ClientId::new("publisher").unwrap(), 1L),
    (@session.ClientId::new("subscriber").unwrap(), 2L),
  ])
  let packet_id = @protocol.PacketId::new(7).unwrap()
  let event : PacketReceivedEvent = {
    connection_id: publisher,
    received_at_ms: 3L,
    packet: Publish({
      topic: "topic",
      payload: b"value",
      qos: QoS1,
      packet_id: Some(packet_id),
      dup: false,
      retain: true,
    }),
  }
  let prepared = rt.prepare_strict_active_packet(event, generations)
  let (plan, after) = match prepared {
    StrictPrepared(plan, after) => (plan, after)
    _ => fail("strict publication must prepare")
  }
  let before = rt.broker_state().export_snapshot()
  assert_eq(coordinator.submit(plan, after), Ok(1L))
  assert_eq(rt.broker_state().export_snapshot(), before)
  @async.with_task_group() <| group => {
    let task = group.spawn(() => writer.run(() => ()))
    let mut result : Array[RuntimeAction]? = None
    for _ in 0..<1000 {
      match coordinator.poll() {
        CommitReleased(actions, _, _) => {
          result = Some(actions)
          break
        }
        CommitFencedResult(reason) => fail("WAL fenced: " + reason)
        NoCommitCompletion => @async.sleep(1)
        _ => fail("unexpected checkpoint completion")
      }
    }
    let actions = result.unwrap()
    assert_eq(
      actions[0],
      SendPacket({ connection_id: publisher, packet: Puback(packet_id) }),
    )
    assert_true(
      actions[1] is SendPacket({ connection_id: _, packet: Publish(_) }),
    )
    assert_eq(rt.broker_state().inflight_count(), 1)
    assert_eq(rt.broker_state().retained_count(), 1)
    let unsubscribe = rt.prepare_strict_active_packet(
      {
        connection_id: subscriber,
        received_at_ms: 4L,
        packet: Unsubscribe({
          packet_id: @protocol.PacketId::new(2).unwrap(),
          topic_filters: ["topic"],
        }),
      },
      generations,
    )
    let (plan, after) = match unsubscribe {
      StrictPrepared(plan, after) => (plan, after)
      _ => fail("strict unsubscribe must prepare")
    }
    assert_eq(coordinator.submit(plan, after), Ok(2L))
    assert_eq(rt.broker_state().subscription_count(), 1)
    let mut removed : Array[RuntimeAction]? = None
    for _ in 0..<1000 {
      match coordinator.poll() {
        CommitReleased(actions, _, _) => {
          removed = Some(actions)
          break
        }
        CommitFencedResult(reason) => fail("WAL fenced: " + reason)
        NoCommitCompletion => @async.sleep(1)
        _ => fail("unexpected checkpoint completion")
      }
    }
    assert_true(removed.unwrap()[0] is SendPacket({ packet: Unsuback(_), .. }))
    assert_eq(rt.broker_state().subscription_count(), 0)
    let subscribe = rt.prepare_strict_active_packet(
      {
        connection_id: subscriber,
        received_at_ms: 5L,
        packet: Subscribe({
          packet_id: @protocol.PacketId::new(3).unwrap(),
          subscriptions: [{ topic_filter: "topic", requested_qos: QoS1 }],
        }),
      },
      generations,
    )
    let (plan, after) = match subscribe {
      StrictPrepared(plan, after) => (plan, after)
      _ => fail("strict subscribe must prepare")
    }
    assert_eq(coordinator.submit(plan, after), Ok(3L))
    assert_eq(rt.broker_state().subscription_count(), 0)
    let mut added : Array[RuntimeAction]? = None
    for _ in 0..<1000 {
      match coordinator.poll() {
        CommitReleased(actions, _, _) => {
          added = Some(actions)
          break
        }
        CommitFencedResult(reason) => fail("WAL fenced: " + reason)
        NoCommitCompletion => @async.sleep(1)
        _ => fail("unexpected checkpoint completion")
      }
    }
    assert_true(added.unwrap()[0] is SendPacket({ packet: Suback(_), .. }))
    assert_eq(rt.broker_state().subscription_count(), 1)
    writer.close_requests()
    task.wait()
    writer.close_store()
  }
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
}

///|
test "strict CONNECT activation and CONNACK stay pending until commit" {
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let rt = BrokerRuntime::new(config, @router.BrokerState::new(broker_config))
  let connection_id = ConnectionId::new(91L)
  ignore(rt.apply(TransportOpened({ connection_id, accepted_at_ms: 1L })))
  let packet : @protocol.ConnectPacket = {
    client_id: "strict-connect",
    username: None,
    password: None,
    keep_alive: 10,
    clean_session: false,
    will: None,
  }
  let prepared = rt.prepare_strict_connect_packet(
    { connection_id, packet: Connect(packet), received_at_ms: 2L },
    Map([]),
    1L,
  )
  let (plan, after) = match prepared {
    StrictPrepared(plan, after) => (plan, after)
    _ => fail("strict connect must prepare")
  }
  assert_eq(rt.broker_state().session_count(), 0)
  assert_eq(
    rt.active_connection(@session.ClientId::new("strict-connect").unwrap()),
    None,
  )
  rt.broker_state().begin_action_scope()
  let broker_actions = plan.commit().unwrap()
  let actions = after(broker_actions)
  rt.broker_state().end_action_scope()
  assert_eq(
    actions[0],
    SendPacket({
      connection_id,
      packet: Connack({ session_present: false, return_code: Accepted }),
    }),
  )
  assert_eq(rt.broker_state().session_count(), 1)
  assert_eq(rt.check_invariants(), Ok(()))
}

///|
test "cancelled strict CONNECT releases reserved Will and session owner" {
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let rt = BrokerRuntime::new(config, @router.BrokerState::new(broker_config))
  let connection_id = ConnectionId::new(92L)
  ignore(rt.apply(TransportOpened({ connection_id, accepted_at_ms: 1L })))
  let occupied = rt.broker_state().resource_ledger().occupied()
  let packet : @protocol.ConnectPacket = {
    client_id: "will-client",
    username: None,
    password: None,
    keep_alive: 10,
    clean_session: false,
    will: Some({
      topic: "will/topic",
      payload: b"offline",
      qos: QoS1,
      retain: true,
    }),
  }
  let prepared = rt.prepare_strict_connect_packet(
    { connection_id, packet: Connect(packet), received_at_ms: 2L },
    Map([]),
    1L,
  )
  match prepared {
    StrictPrepared(plan, _) => plan.cancel()
    _ => fail("strict Will connect must prepare")
  }
  assert_eq(rt.broker_state().resource_ledger().occupied(), occupied)
  assert_eq(rt.broker_state().session_count(), 0)
}

///|
test "strict takeover closes old transport after durable activation and queues its Will" {
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let runtime = BrokerRuntime::new(
    config,
    @router.BrokerState::new(broker_config),
  )
  let old_id = ConnectionId::new(101L)
  let new_id = ConnectionId::new(102L)
  ignore(
    runtime.apply(
      TransportOpened({ connection_id: old_id, accepted_at_ms: 0L }),
    ),
  )
  ignore(
    runtime.apply(
      PacketReceived({
        connection_id: old_id,
        received_at_ms: 1L,
        packet: Connect({
          client_id: "same",
          username: None,
          password: None,
          keep_alive: 10,
          clean_session: false,
          will: Some({
            topic: "will/topic",
            payload: b"old",
            qos: QoS1,
            retain: true,
          }),
        }),
      }),
    ),
  )
  ignore(
    runtime.apply(
      TransportOpened({ connection_id: new_id, accepted_at_ms: 2L }),
    ),
  )
  let client = @session.ClientId::new("same").unwrap()
  let prepared = runtime.prepare_strict_connect_packet(
    {
      connection_id: new_id,
      received_at_ms: 3L,
      packet: Connect({
        client_id: "same",
        username: None,
        password: None,
        keep_alive: 10,
        clean_session: false,
        will: None,
      }),
    },
    Map([(client, 1L)]),
    2L,
  )
  let (plan, after) = match prepared {
    StrictPrepared(plan, after) => (plan, after)
    _ => fail("takeover must prepare")
  }
  assert_true(runtime.has_connection(old_id))
  assert_eq(runtime.active_connection(client), Some(old_id))
  runtime.broker_state().begin_action_scope()
  let actions = after(plan.commit().unwrap())
  runtime.broker_state().end_action_scope()
  assert_false(runtime.has_connection(old_id))
  assert_eq(runtime.active_connection(client), Some(new_id))
  assert_true(
    actions.any(action => action is StartDurableWill(id) && id == old_id),
  )
  let pending = runtime.take_strict_pending_will(old_id).unwrap()
  assert_eq(pending.1.payload, b"old")
  release_optional(pending.2)
  assert_eq(runtime.check_invariants(), Ok(()))
}

///|
test "strict authenticated CONNECT can prepare from Authenticating phase" {
  let broker_config = @router.BrokerConfig::new(4, 16, 4).unwrap()
  let config = ServerConfig::new(4, 1024, 2048, 8, 32, 1000, 100, broker_config).unwrap()
  let runtime = BrokerRuntime::new(
    config,
    @router.BrokerState::new(broker_config),
  )
  let connection_id = ConnectionId::new(103L)
  ignore(runtime.apply(TransportOpened({ connection_id, accepted_at_ms: 1L })))
  let meta = runtime.connections.get(connection_id).unwrap()
  runtime.connections.set(connection_id, { ..meta, phase: Authenticating(7L) })
  let prepared = runtime.prepare_strict_accepted_connect(
    connection_id,
    {
      client_id: "authenticated",
      username: None,
      password: None,
      keep_alive: 10,
      clean_session: false,
      will: None,
    },
    2L,
    @security.Principal::Anonymous,
    Map([]),
    1L,
  )
  match prepared {
    StrictPrepared(plan, _) => plan.cancel()
    _ => fail("authenticated CONNECT must prepare durable activation")
  }
  assert_eq(runtime.broker_state().session_count(), 0)
}
