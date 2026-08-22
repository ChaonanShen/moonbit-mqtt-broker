///|
fn persistent_client(value : String) -> @session.ClientId {
  @session.ClientId::new(value).unwrap()
}

///|
fn persistent_topic(value : String) -> @topic.TopicName {
  @topic.TopicName::new(value).unwrap()
}

///|
fn persistent_filter(value : String) -> @topic.TopicFilter {
  @topic.TopicFilter::new(value).unwrap()
}

///|
fn create_persistent(
  state : BrokerState,
  client_id : @session.ClientId,
  attached : Bool,
) -> Unit {
  ignore(
    state.apply(
      BrokerEvent::CreateSessionWith({
        client_id,
        mode: @session.SessionMode::Persistent,
        attached,
      }),
    ),
  )
}

///|
test "persistent reconnect sets session present and preserves subscriptions" {
  let state = BrokerState::new(BrokerConfig::new(4, 16, 4).unwrap())
  let subscriber = persistent_client("subscriber")
  create_persistent(state, subscriber, true)
  ignore(
    state.apply(
      Subscribe({
        client_id: subscriber,
        entries: [
          {
            filter: persistent_filter("offline/#"),
            qos: @session.DeliveryQoS::QoS1,
          },
        ],
      }),
    ),
  )
  assert_eq(
    state.apply(DetachSession(subscriber)),
    Ok([SessionDetached(subscriber)]),
  )
  assert_eq(state.session_attached(subscriber), Some(false))
  assert_eq(
    state.subscription_qos(subscriber, persistent_filter("offline/#")),
    Some(@session.DeliveryQoS::QoS1),
  )
  assert_eq(
    state.apply(AttachSession(subscriber)),
    Ok([SessionAttached(subscriber)]),
  )
  assert_eq(state.session_attached(subscriber), Some(true))
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "offline persistent session queues qos1 but drops qos0" {
  let config = BrokerConfig::new(
    4,
    16,
    4,
    max_inflight_per_session=1,
    max_inflight_total=4,
    max_pending_qos1_per_session=4,
    max_pending_qos1_total=8,
  ).unwrap()
  let state = BrokerState::new(config)
  let subscriber = persistent_client("offline")
  create_persistent(state, subscriber, false)
  ignore(
    state.apply(
      Subscribe({
        client_id: subscriber,
        entries: [
          {
            filter: persistent_filter("queued"),
            qos: @session.DeliveryQoS::QoS1,
          },
        ],
      }),
    ),
  )
  let publish = fn(qos) {
    state
    .apply(
      Publish({
        origin: PublishOrigin::Internal,
        topic: persistent_topic("queued"),
        payload: b"message",
        qos,
        retain: false,
      }),
    )
    .unwrap()
  }
  assert_eq(publish(@session.DeliveryQoS::QoS0), [])
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(publish(@session.DeliveryQoS::QoS1), [])
  assert_eq(state.pending_qos1_count(), 1)
  assert_eq(
    state.apply(AttachSession(subscriber)),
    Ok([
      SessionAttached(subscriber),
      Deliver({
        recipient: subscriber,
        topic: persistent_topic("queued"),
        payload: b"message",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
        packet_id: Some(@session.SessionPacketId::new(1).unwrap()),
        dup: false,
      }),
    ]),
  )
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(state.inflight_count(), 1)
}

///|
test "unacknowledged broker qos1 replay keeps packet id and sets dup" {
  let state = BrokerState::new(BrokerConfig::new(2, 4, 1).unwrap())
  let subscriber = persistent_client("replay")
  create_persistent(state, subscriber, true)
  ignore(
    state.apply(
      Subscribe({
        client_id: subscriber,
        entries: [
          {
            filter: persistent_filter("replay"),
            qos: @session.DeliveryQoS::QoS1,
          },
        ],
      }),
    ),
  )
  let first = state
    .apply(
      Publish({
        origin: Internal,
        topic: persistent_topic("replay"),
        payload: b"saved",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      }),
    )
    .unwrap()[0]
  let packet_id = match first {
    Deliver(delivery) => delivery.packet_id.unwrap()
    _ => fail("qos1 publish must deliver")
  }
  ignore(state.apply(DetachSession(subscriber)))
  let replay = state.apply(AttachSession(subscriber)).unwrap()
  match replay[1] {
    Deliver(delivery) => {
      assert_eq(delivery.packet_id, Some(packet_id))
      assert_true(delivery.dup)
      assert_eq(delivery.payload, b"saved")
    }
    _ => fail("reconnect must replay inflight")
  }
}

///|
test "session inflight and pending limits are atomic" {
  let config = BrokerConfig::new(
    2,
    4,
    1,
    max_inflight_per_session=0,
    max_inflight_total=0,
    max_pending_qos1_per_session=1,
    max_pending_qos1_total=1,
  ).unwrap()
  let state = BrokerState::new(config)
  let alice = persistent_client("alice")
  let bob = persistent_client("bob")
  for client in [alice, bob] {
    create_persistent(state, client, false)
    ignore(
      state.apply(
        Subscribe({
          client_id: client,
          entries: [
            {
              filter: persistent_filter("atomic"),
              qos: @session.DeliveryQoS::QoS1,
            },
          ],
        }),
      ),
    )
  }
  assert_true(
    state.apply(
      Publish({
        origin: Client(alice),
        topic: persistent_topic("atomic"),
        payload: b"all-or-nothing",
        qos: @session.DeliveryQoS::QoS1,
        retain: true,
      }),
    )
    is Err(QoS1ResourceLimit(_, PendingQoS1Total)),
  )
  assert_eq(state.pending_qos1_count(), 0)
  assert_eq(state.retained_count(), 0)
  assert_eq(state.session_pending_count(alice), Some(0))
  assert_eq(state.session_pending_count(bob), Some(0))
  assert_eq(state.check_invariants(), Ok(()))
}

///|
test "puback promotes pending qos1 in fifo order at broker state" {
  let config = BrokerConfig::new(
    2,
    4,
    1,
    max_inflight_per_session=1,
    max_inflight_total=1,
    max_pending_qos1_per_session=2,
    max_pending_qos1_total=2,
  ).unwrap()
  let state = BrokerState::new(config)
  let client = persistent_client("ack")
  create_persistent(state, client, true)
  ignore(
    state.apply(
      Subscribe({
        client_id: client,
        entries: [
          { filter: persistent_filter("ack"), qos: @session.DeliveryQoS::QoS1 },
        ],
      }),
    ),
  )
  let publish = fn(payload) {
    state
    .apply(
      Publish({
        origin: Internal,
        topic: persistent_topic("ack"),
        payload,
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      }),
    )
    .unwrap()
  }
  let first = match publish(b"first")[0] {
    Deliver(delivery) => delivery
    _ => fail("first delivery must be inflight")
  }
  assert_eq(publish(b"second"), [])
  let actions = state
    .apply(Puback({ client_id: client, packet_id: first.packet_id.unwrap() }))
    .unwrap()
  assert_eq(
    actions[0],
    DeliveryAcknowledged({
      client_id: client,
      packet_id: first.packet_id.unwrap(),
    }),
  )
  match actions[1] {
    Deliver(delivery) => {
      assert_eq(delivery.payload, b"second")
      assert_false(delivery.dup)
    }
    _ => fail("PUBACK must promote pending delivery")
  }
  assert_eq(state.inflight_count(), 1)
  assert_eq(state.pending_qos1_count(), 0)
}
