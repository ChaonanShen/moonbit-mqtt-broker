///|
fn q2_message(value : String, qos? : DeliveryQoS = QoS2) -> SessionMessage {
  SessionMessage::new(
    @topic.TopicName::new("q2").unwrap(),
    @utf8.encode(value),
    false,
    qos~,
  )
}

///|
fn q2_stage(
  session : ClientSession,
  message : SessionMessage,
  limits : SessionLimits,
) -> SessionDelivery raise {
  match session.stage(message, limits).unwrap() {
    SendNow(delivery) => delivery
    _ => fail("expected inflight delivery")
  }
}

///|
test "qos2 phase transitions release payload before packet id and promote mixed fifo" {
  let s = ClientSession::new(ClientId::new("phases").unwrap(), mode=Persistent)
  let limits = SessionLimits::new(1, 3).unwrap()
  let first = q2_stage(s, q2_message("large"), limits)
  assert_eq(s.stage(q2_message("q1", qos=QoS1), limits), Ok(Queued))
  assert_eq(s.stage(q2_message("q2"), limits), Ok(Queued))
  let before = s.outbound_message_bytes()
  assert_eq(s.pubrec(first.packet_id), Ok(true))
  assert_eq(s.inflight_count(), 1)
  assert_eq(s.inflight()[0].message, None)
  assert_eq(before - s.outbound_message_bytes(), 7L)
  assert_eq(s.pubrec(first.packet_id), Ok(false))
  assert_eq(s.ack(first.packet_id, limits), Err(InvalidAcknowledgement))
  let second = match s.ack(first.packet_id, limits, pubcomp=true).unwrap() {
    Acknowledged(deliveries) => deliveries[0]
    _ => fail("PUBCOMP should promote pending")
  }
  assert_eq(second.message.unwrap().qos, QoS1)
  let third = match s.ack(second.packet_id, limits).unwrap() {
    Acknowledged(deliveries) => deliveries[0]
    _ => fail("PUBACK should promote pending")
  }
  assert_eq(third.message.unwrap().qos, QoS2)
  ignore(s.pubrec(third.packet_id).unwrap())
  ignore(s.ack(third.packet_id, limits, pubcomp=true).unwrap())
  assert_eq(s.outbound_message_bytes(), 0L)
  assert_eq(s.check_invariants(limits), Ok(()))
}

///|
test "qos2 acknowledgement cartesian matrix preserves mismatched phases" {
  let limits = SessionLimits::new(2, 2).unwrap()
  for phase in [OutboundPhase::AwaitPuback, AwaitPubrec, AwaitPubcomp] {
    for ack in 0..<3 {
      let s = ClientSession::new(ClientId::new("matrix").unwrap())
      let first = q2_stage(
        s,
        q2_message("body", qos=if phase == AwaitPuback { QoS1 } else { QoS2 }),
        limits,
      )
      if phase == AwaitPubcomp {
        ignore(s.pubrec(first.packet_id).unwrap())
      }
      let before = s.inflight()
      match ack {
        0 =>
          if phase != AwaitPuback {
            assert_eq(
              s.ack(first.packet_id, limits),
              Err(InvalidAcknowledgement),
            )
            assert_eq(s.inflight(), before)
          } else {
            ignore(s.ack(first.packet_id, limits).unwrap())
          }
        1 =>
          if phase == AwaitPuback {
            assert_eq(s.pubrec(first.packet_id), Err(InvalidAcknowledgement))
            assert_eq(s.inflight(), before)
          } else {
            ignore(s.pubrec(first.packet_id).unwrap())
          }
        _ =>
          if phase != AwaitPubcomp {
            assert_eq(
              s.ack(first.packet_id, limits, pubcomp=true),
              Err(InvalidAcknowledgement),
            )
            assert_eq(s.inflight(), before)
          } else {
            ignore(s.ack(first.packet_id, limits, pubcomp=true).unwrap())
          }
      }
      let unknown = SessionPacketId::new(60000).unwrap()
      assert_eq(s.pubrec(unknown), Ok(false))
      assert_eq(s.ack(unknown, limits), Ok(UnknownPacketId))
      assert_eq(s.ack(unknown, limits, pubcomp=true), Ok(UnknownPacketId))
      assert_eq(s.check_invariants(limits), Ok(()))
    }
  }
}

///|
test "qos2 replay preserves publish and first pubrec order independently" {
  let limits = SessionLimits::new(4, 2).unwrap()
  let s = ClientSession::new(ClientId::new("order").unwrap(), mode=Persistent)
  let a = q2_stage(s, q2_message("a"), limits)
  let b = q2_stage(s, q2_message("b"), limits)
  let c = q2_stage(s, q2_message("c"), limits)
  let d = q2_stage(s, q2_message("d", qos=QoS1), limits)
  ignore(s.pubrec(c.packet_id).unwrap())
  ignore(s.pubrec(a.packet_id).unwrap())
  ignore(s.pubrec(c.packet_id).unwrap())
  s.detach()
  let replay = s.attach(limits).unwrap()
  assert_eq(replay.map(item => item.packet_id), [
    b.packet_id,
    d.packet_id,
    c.packet_id,
    a.packet_id,
  ])
  assert_eq(replay.map(item => item.message is None), [false, false, true, true])
  assert_eq(replay.map(item => item.dup), [true, true, false, false])
  assert_eq(s.check_invariants(limits), Ok(()))
}

///|
test "qos2 inbound ids are independent bounded and reusable across allocator wrap" {
  let limits = SessionLimits::new(4, 2, max_inbound_qos2=1).unwrap()
  let client = ClientId::new("wrap").unwrap()
  let s = ClientSession::restore(client, 65535, [], []).unwrap()
  ignore(s.attach(limits).unwrap())
  let first = q2_stage(s, q2_message("first"), limits)
  assert_eq(first.packet_id.value(), 65535)
  assert_eq(s.begin_inbound_qos2(first.packet_id, limits), Ok(true))
  assert_eq(s.begin_inbound_qos2(first.packet_id, limits), Ok(false))
  assert_true(
    s.begin_inbound_qos2(SessionPacketId::new(1).unwrap(), limits)
    is Err(InboundQoS2LimitReached(1)),
  )
  ignore(s.pubrec(first.packet_id).unwrap())
  let restored = ClientSession::restore(
    client,
    65535,
    s.inflight(),
    [],
    inbound_qos2=s.inbound_qos2(),
  ).unwrap()
  ignore(restored.attach(limits).unwrap())
  let second = q2_stage(restored, q2_message("next", qos=QoS1), limits)
  assert_eq(second.packet_id.value(), 1)
  assert_true(restored.complete_inbound_qos2(first.packet_id))
  assert_false(restored.complete_inbound_qos2(first.packet_id))
  assert_eq(restored.begin_inbound_qos2(first.packet_id, limits), Ok(true))
  assert_eq(restored.check_invariants(limits), Ok(()))
}

///|
test "qos minimum and maximum cover all nine pairs" {
  let values : Array[DeliveryQoS] = [QoS0, QoS1, QoS2]
  for i in 0..<3 {
    for j in 0..<3 {
      assert_eq(
        min_qos(values[i], values[j]),
        values[if i < j { i } else { j }],
      )
      assert_eq(
        max_qos(values[i], values[j]),
        values[if i > j { i } else { j }],
      )
    }
  }
}

///|
test "byte-blocked pending head cannot be bypassed by a smaller new message" {
  let session = ClientSession::new(ClientId::new("bytes-fifo").unwrap())
  let topic = @topic.TopicName::new("t").unwrap()
  let limits = SessionLimits::new(2, 4, max_inflight_bytes=197L).unwrap()
  let first = match
    session.stage(SessionMessage::new(topic, b"123", false), limits).unwrap() {
    SendNow(d) => d
    _ => fail("first must send")
  }
  assert_eq(
    session.stage(SessionMessage::new(topic, b"1234", false), limits),
    Ok(Queued),
  )
  assert_eq(
    session.stage(SessionMessage::new(topic, b"", false), limits),
    Ok(Queued),
  )
  assert_eq(session.inflight_count(), 1)
  let next = match session.ack(first.packet_id, limits).unwrap() {
    Acknowledged(ds) => ds
    _ => fail("must acknowledge")
  }
  assert_eq(next.length(), 1)
  assert_eq(next[0].message.unwrap().payload, b"1234")
  assert_eq(session.pending_count(), 1)
  assert_eq(session.check_invariants(limits), Ok(()))
}
