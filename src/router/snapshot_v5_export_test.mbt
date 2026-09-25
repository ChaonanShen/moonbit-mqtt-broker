///|
test "C-T30 V5 snapshot export retains subscription and message metadata" {
  let state = BrokerState::new(BrokerConfig::new(8, 16, 8).unwrap())
  let publisher = @session.ClientId::new("export-pub").unwrap()
  let subscriber = @session.ClientId::new("export-sub").unwrap()
  ignore(state.apply(CreateSession(publisher)))
  ignore(
    state.apply(
      CreateSessionWith({
        client_id: subscriber,
        mode: @session.Persistent,
        attached: true,
      }),
    ),
  )
  ignore(
    state.apply(
      SubscribeV5({
        client_id: subscriber,
        entries: [
          {
            filter: @topic.TopicFilter::new("export/#").unwrap(),
            qos: @session.QoS1,
            no_local: true,
            retain_as_published: true,
            retain_handling: 1,
            subscription_identifier: Some(7),
          },
        ],
      }),
    ),
  )
  let base_mono_ms = @budget.monotonic_ms()
  let metadata : @session.MessageMetadata = {
    ..@session.MessageMetadata::empty(),
    content_type: Some("text/plain"),
    user_properties: [("k", "v")],
    publisher_client_id: Some(publisher),
    expiry: Some(
      @session.Deadline::from_seconds(base_mono_ms, 1000L, 10U).unwrap(),
    ),
  }
  ignore(
    state
    .apply(
      PublishV5({
        publish: {
          origin: Client(publisher),
          topic: @topic.TopicName::new("export/a").unwrap(),
          payload: b"value",
          qos: @session.QoS1,
          retain: false,
        },
        metadata,
      }),
    )
    .unwrap(),
  )
  let snapshot = state.export_snapshot_v5(base_mono_ms + 1000L, 2000L).unwrap()
  assert_eq(snapshot.sessions.length(), 1)
  assert_eq(
    snapshot.sessions[0].subscriptions[0].subscription_identifier,
    Some(7U),
  )
  assert_eq(snapshot.sessions[0].inflight[0].subscription_identifiers, [7U])
  assert_eq(
    snapshot.sessions[0].inflight[0].message.unwrap().properties.content_type,
    Some("text/plain"),
  )
  assert_eq(
    snapshot.sessions[0].inflight[0].message.unwrap().expiry_clock.unwrap().remaining_ms,
    9000L,
  )
  assert_true(
    snapshot.next_delivery_id > snapshot.sessions[0].inflight[0].delivery_id,
  )
  let restored = BrokerState::from_snapshot_v5(
    BrokerConfig::new(8, 16, 8).unwrap(),
    snapshot,
    base_mono_ms + 2000L,
    3100L,
  ).unwrap()
  let recovered = restored
    .export_snapshot_v5(base_mono_ms + 2000L, 3100L)
    .unwrap()
  assert_eq(
    recovered.sessions[0].subscriptions[0].subscription_identifier,
    Some(7U),
  )
  assert_eq(recovered.sessions[0].inflight[0].subscription_identifiers, [7U])
  assert_eq(
    recovered.sessions[0].inflight[0].message.unwrap().properties.content_type,
    Some("text/plain"),
  )
  assert_eq(
    recovered.sessions[0].inflight[0].message.unwrap().expiry_clock.unwrap().remaining_ms,
    7900L,
  )
  assert_eq(restored.check_invariants(), Ok(()))
}
