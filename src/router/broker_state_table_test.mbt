///|
struct TableRun {
  outputs : Array[Result[Array[BrokerAction], RouterError]]
  session_count : Int
  subscription_count : Int
  retained_count : Int
  subscriptions : Array[@session.DeliveryQoS?]
  retained_payloads : Array[Bytes?]
} derive(Eq, Debug)

///|
fn table_client(index : Int) -> @session.ClientId {
  @session.ClientId::new("client-\{index}").unwrap()
}

///|
fn table_filter(index : Int) -> @topic.TopicFilter {
  @topic.TopicFilter::new("topic/\{index}/#").unwrap()
}

///|
fn table_topic(index : Int) -> @topic.TopicName {
  @topic.TopicName::new("topic/\{index}/value").unwrap()
}

///|
fn table_event(iteration : Int) -> BrokerEvent {
  let client = table_client(iteration % 10)
  let slot = iteration / 7 % 5
  match iteration % 7 {
    0 => BrokerEvent::CreateSession(client)
    1 =>
      BrokerEvent::Subscribe({
        client_id: client,
        entries: [
          {
            filter: table_filter(slot),
            qos: if iteration % 2 == 0 {
              @session.DeliveryQoS::QoS0
            } else {
              @session.DeliveryQoS::QoS1
            },
          },
        ],
      })
    2 =>
      BrokerEvent::Publish({
        origin: PublishOrigin::Client(client),
        topic: table_topic(slot),
        payload: b"live",
        qos: @session.DeliveryQoS::QoS1,
        retain: false,
      })
    3 =>
      BrokerEvent::Unsubscribe({
        client_id: client,
        filters: [table_filter(slot)],
      })
    4 =>
      BrokerEvent::Publish({
        origin: PublishOrigin::Internal,
        topic: @topic.TopicName::new("retained/\{slot}").unwrap(),
        payload: b"saved",
        qos: @session.DeliveryQoS::QoS0,
        retain: true,
      })
    5 => BrokerEvent::RemoveSession(client)
    _ =>
      BrokerEvent::Publish({
        origin: PublishOrigin::Will(client),
        topic: @topic.TopicName::new("$SYS/health").unwrap(),
        payload: b"ok",
        qos: @session.DeliveryQoS::QoS0,
        retain: false,
      })
  }
}

///|
fn run_table() -> TableRun raise {
  let state = BrokerState::new(BrokerConfig::new(5, 50, 5).unwrap())
  let outputs : Array[Result[Array[BrokerAction], RouterError]] = []
  for iteration in 0..<10000 {
    let output = state.apply(table_event(iteration))
    match output {
      Err(RouterError::SessionAlreadyExists(_))
      | Err(RouterError::SessionNotFound(_)) => ()
      Err(_) => fail("unexpected router error in deterministic sequence")
      Ok(_) => ()
    }
    outputs.push(output)
    if iteration % 10 == 0 {
      assert_eq(state.check_invariants(), Ok(()))
    }
  }
  let subscriptions = []
  for client_index in 0..<10 {
    for filter_index in 0..<5 {
      subscriptions.push(
        state.subscription_qos(
          table_client(client_index),
          table_filter(filter_index),
        ),
      )
    }
  }
  let retained_payloads = []
  for index in 0..<5 {
    let topic = @topic.TopicName::new("retained/\{index}").unwrap()
    retained_payloads.push(
      state.retained_message(topic).map(fn(message) { message.payload }),
    )
  }
  {
    outputs,
    session_count: state.session_count(),
    subscription_count: state.subscription_count(),
    retained_count: state.retained_count(),
    subscriptions,
    retained_payloads,
  }
}

///|
test "ten thousand deterministic router transitions" {
  let first = run_table()
  let second = run_table()
  assert_eq(first, second)
}
