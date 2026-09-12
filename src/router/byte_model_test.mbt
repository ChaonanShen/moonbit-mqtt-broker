///|
fn model_message_cost(topic : String, payload : Bytes) -> Int64 {
  @utf8.encode(topic).length().to_int64() + payload.length().to_int64() + 96L
}

///|
fn model_snapshot_cost(snapshot : BrokerSnapshotV3) -> Int64 {
  let mut cost = 0L
  for saved in snapshot.sessions {
    cost += @utf8.encode(saved.client_id).length().to_int64() +
      @utf8.encode(saved.owner_principal).length().to_int64() +
      256L
    for subscription in saved.subscriptions {
      cost += @utf8.encode(subscription.filter).length().to_int64() + 64L
    }
    cost += saved.inbound_qos2.length().to_int64() * 64L
    for item in saved.inflight {
      cost += match item.message {
        None => 64L
        Some(message) => model_message_cost(message.topic, message.payload)
      }
    }
    for message in saved.pending {
      cost += model_message_cost(message.topic, message.payload)
    }
  }
  for message in snapshot.retained {
    cost += model_message_cost(message.topic, message.payload)
  }
  cost
}

///|
test "ten thousand mixed router operations match an independent snapshot cost model" {
  let state = bytes_state(
    [
      ("max_inflight_bytes_per_session", 300L),
      ("max_pending_bytes_per_session", 400L),
      ("max_session_state_bytes", 800L),
      ("max_inflight_bytes_total", 600L),
      ("max_pending_bytes_total", 800L),
      ("max_retained_bytes_total", 400L),
    ],
    inflight=2,
  )
  let ids = ["model-a", "model-b", "model-c", "model-d"].map(name => {
    bytes_client(state, name)
  })
  for id in ids {
    ignore(bytes_subscribe(state, id, "#"))
  }
  let mut seed = 23
  for step in 0..<10000 {
    seed = (seed * 73 + 19) % 1009
    let id = ids[seed % 4]
    let before = state.export_snapshot()
    let bytes = state.managed_bytes()
    let revision = state.snapshot_revision()
    let packet_id = @session.SessionPacketId::new(1 + seed % 8).unwrap()
    let topic = @topic.TopicName::new("测/" + (seed % 3).to_string()).unwrap()
    let event : BrokerEvent = match seed % 8 {
      0 | 1 =>
        ReceiveQoS2({
          client_id: id,
          packet_id,
          publish: Some({
            origin: Client(id),
            topic,
            payload: Bytes::make(seed % 10, 65),
            qos: QoS2,
            retain: seed % 2 == 0,
          }),
        })
      2 => Pubrel({ client_id: id, packet_id })
      3 => {
        let mut ack : BrokerEvent = Puback({ client_id: id, packet_id })
        for saved in before.sessions {
          if saved.client_id == id.value() && !saved.inflight.is_empty() {
            let item = saved.inflight[0]
            let request : PubackRequest = {
              client_id: id,
              packet_id: @session.SessionPacketId::new(item.packet_id).unwrap(),
            }
            ack = match item.phase {
              1 => Puback(request)
              2 => Pubrec(request)
              _ => Pubcomp(request)
            }
          }
        }
        ack
      }
      4 =>
        Publish({
          origin: Client(id),
          topic,
          payload: b"",
          qos: QoS0,
          retain: true,
        })
      5 =>
        if state.subscription_qos(id, @topic.TopicFilter::new("#").unwrap())
          is Some(_) {
          Unsubscribe({
            client_id: id,
            filters: [@topic.TopicFilter::new("#").unwrap()],
          })
        } else {
          Subscribe({
            client_id: id,
            entries: [
              { filter: @topic.TopicFilter::new("#").unwrap(), qos: QoS2 },
            ],
          })
        }
      6 =>
        if state.session_attached(id) == Some(true) {
          DetachSessionAt({ client_id: id, detached_at_ms: step.to_int64() })
        } else {
          AttachSession(id)
        }
      _ =>
        if state.has_session(id) {
          RemoveSession(id)
        } else {
          CreateSessionWith({ client_id: id, mode: Persistent, attached: true })
        }
    }
    let result = state.apply(event)
    if result is Err(_) {
      assert_eq(state.export_snapshot(), before)
      assert_eq(state.managed_bytes(), bytes)
      assert_eq(state.snapshot_revision(), revision)
    }
    assert_eq(state.check_invariants(), Ok(()))
    assert_eq(
      state.managed_bytes(),
      model_snapshot_cost(state.export_snapshot()),
    )
  }
}
