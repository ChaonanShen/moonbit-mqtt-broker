///|
fn q2_publish(
  id : Int,
  payload? : Bytes = b"first",
  dup? : Bool = false,
  retain? : Bool = true,
  topic? : String = "q2/live",
) -> @protocol.Packet {
  Publish({
    topic,
    payload,
    qos: QoS2,
    packet_id: Some(@protocol.PacketId::new(id).unwrap()),
    dup,
    retain,
  })
}

///|
fn q2_sub(
  rt : BrokerRuntime,
  connection : ConnectionId,
  qos? : @protocol.QoS = QoS2,
  topic? : String = "q2/#",
) -> Unit raise {
  let actions = receive(
    rt,
    connection,
    Subscribe({
      packet_id: @protocol.PacketId::new(55).unwrap(),
      subscriptions: [{ topic_filter: topic, requested_qos: qos }],
    }),
    2L,
  )
  match actions[0] {
    SendPacket({ packet: Suback({ return_codes, .. }), .. }) =>
      assert_eq(return_codes, [
        match qos {
          QoS0 => GrantedQoS0
          QoS1 => GrantedQoS1
          QoS2 => GrantedQoS2
        },
      ])
    _ => fail("expected SUBACK")
  }
}

///|
test "qos2 method b duplicates preserve first retained and route exactly once including self" {
  let rt = runtime()
  persistent_connect(rt, cid(1L), "self", false)
  q2_sub(rt, cid(1L))
  let incoming = @protocol.PacketId::new(7).unwrap()
  let actions = receive(rt, cid(1L), q2_publish(7, dup=true), 3L)
  assert_eq(actions.length(), 2)
  assert_eq(
    actions[0],
    SendPacket({ connection_id: cid(1L), packet: Pubrec(incoming) }),
  )
  let outgoing = match actions[1] {
    SendPacket({ packet: Publish(packet), .. }) => packet.packet_id.unwrap()
    _ => fail("first publication must route")
  }
  let saved = rt.broker_state().export_snapshot()
  let revision = rt.broker_state().snapshot_revision()
  for index in 0..<100 {
    assert_eq(
      receive(
        rt,
        cid(1L),
        q2_publish(7, payload=b"changed", dup=index % 2 == 0),
        4L,
      ),
      [actions[0]],
    )
  }
  assert_eq(rt.broker_state().snapshot_revision(), revision)
  assert_eq(rt.broker_state().export_snapshot(), saved)
  assert_eq(rt.broker_state().inbound_qos2_count(), 1)
  assert_eq(rt.check_invariants(), Ok(()))
  assert_eq(receive(rt, cid(1L), Pubrec(outgoing), 5L), [
    SendPacket({ connection_id: cid(1L), packet: Pubrel(outgoing) }),
  ])
  assert_eq(receive(rt, cid(1L), Pubcomp(outgoing), 6L), [])
  for _ in 0..<3 {
    assert_eq(receive(rt, cid(1L), Pubrel(incoming), 7L), [
      SendPacket({ connection_id: cid(1L), packet: Pubcomp(incoming) }),
    ])
  }
  assert_eq(rt.broker_state().inbound_qos2_count(), 0)
  let reused = receive(rt, cid(1L), q2_publish(7, payload=b"", dup=true), 8L)
  assert_eq(reused.length(), 2)
  assert_eq(rt.broker_state().retained_count(), 0)
  assert_eq(rt.metrics().qos2_duplicates(), 100L)
  assert_eq(rt.check_invariants(), Ok(()))
}

///|
test "qos2 publishes and subscriptions negotiate all nine combinations" {
  for published in [@protocol.QoS::QoS0, QoS1, QoS2] {
    for subscribed in [@protocol.QoS::QoS0, QoS1, QoS2] {
      let rt = runtime()
      connect(rt, cid(1L), "subscriber")
      q2_sub(rt, cid(1L), qos=subscribed)
      connect(rt, cid(2L), "publisher")
      let actions = receive(
        rt,
        cid(2L),
        Publish({
          topic: "q2/live",
          payload: b"combo",
          qos: published,
          packet_id: if published == QoS0 {
            None
          } else {
            Some(@protocol.PacketId::new(1).unwrap())
          },
          dup: false,
          retain: false,
        }),
        3L,
      )
      let deliveries = actions.filter(action => {
        action is SendPacket({ packet: Publish(_), .. })
      })
      assert_eq(deliveries.length(), 1)
      let expected : @protocol.QoS = if published == QoS0 || subscribed == QoS0 {
        QoS0
      } else if published == QoS1 || subscribed == QoS1 {
        QoS1
      } else {
        QoS2
      }
      match deliveries[0] {
        SendPacket({ packet: Publish(packet), .. }) =>
          assert_eq(packet.qos, expected)
        _ => fail("expected publication")
      }
      assert_eq(rt.check_invariants(), Ok(()))
    }
  }
}

///|
test "qos2 committed snapshot resumes both outbound phases and inbound deduplication" {
  let rt = runtime()
  persistent_connect(rt, cid(1L), "subscriber", false)
  persistent_connect(rt, cid(2L), "publisher", false)
  q2_sub(rt, cid(1L))
  let a = receive(rt, cid(2L), q2_publish(11), 3L)
  let b = receive(rt, cid(2L), q2_publish(12, payload=b"second"), 4L)
  let first = match a[1] {
    SendPacket({ packet: Publish(p), .. }) => p.packet_id.unwrap()
    _ => fail("expected publish")
  }
  let second = match b[1] {
    SendPacket({ packet: Publish(p), .. }) => p.packet_id.unwrap()
    _ => fail("expected publish")
  }
  ignore(receive(rt, cid(1L), Pubrec(first), 5L))
  let saved = rt.broker_state().export_snapshot()
  assert_eq(saved.version, 3)
  let recovered = BrokerRuntime::new(
    runtime_config(),
    @router.BrokerState::from_snapshot(runtime_config().broker_config(), saved).unwrap(),
  )
  open(recovered, cid(3L), 6L)
  let replay = receive(
    recovered,
    cid(3L),
    connect_packet("subscriber", clean_session=false),
    7L,
  )
  assert_eq(replay.length(), 3)
  assert_eq(
    replay[0],
    SendPacket({
      connection_id: cid(3L),
      packet: Connack({ session_present: true, return_code: Accepted }),
    }),
  )
  match replay[1] {
    SendPacket({ packet: Publish(p), .. }) => {
      assert_eq(p.packet_id, Some(second))
      assert_true(p.dup)
      assert_eq(p.qos, QoS2)
    }
    _ => fail("AwaitPubrec should replay PUBLISH")
  }
  assert_eq(
    replay[2],
    SendPacket({ connection_id: cid(3L), packet: Pubrel(first) }),
  )
  persistent_connect(recovered, cid(4L), "publisher", true)
  assert_eq(
    receive(recovered, cid(4L), q2_publish(11, payload=b"duplicate"), 8L).length(),
    1,
  )
  assert_eq(recovered.broker_state().inflight_count(), 2)
  ignore(receive(recovered, cid(3L), Pubcomp(first), 9L))
  ignore(receive(recovered, cid(3L), Pubrec(second), 10L))
  ignore(receive(recovered, cid(3L), Pubcomp(second), 11L))
  for id in [11, 12] {
    ignore(
      receive(
        recovered,
        cid(4L),
        Pubrel(@protocol.PacketId::new(id).unwrap()),
        12L,
      ),
    )
  }
  let cleared = @router.BrokerState::from_snapshot(
    runtime_config().broker_config(),
    recovered.broker_state().export_snapshot(),
  ).unwrap()
  assert_eq(cleared.inflight_count(), 0)
  assert_eq(cleared.inbound_qos2_count(), 0)
  assert_eq(recovered.check_invariants(), Ok(()))
}

///|
test "qos2 inbound illegal id reuse closes while opposite direction and unknown acks remain independent" {
  for kind in 0..<3 {
    let rt = runtime()
    persistent_connect(rt, cid(1L), "collision", false)
    ignore(receive(rt, cid(1L), q2_publish(9), 2L))
    let id = @protocol.PacketId::new(9).unwrap()
    assert_eq(receive(rt, cid(1L), Pubrec(id), 3L), [
      SendPacket({ connection_id: cid(1L), packet: Pubrel(id) }),
    ])
    assert_eq(receive(rt, cid(1L), Pubcomp(id), 4L), [])
    let packet : @protocol.Packet = match kind {
      0 =>
        Publish({
          topic: "q2/other",
          payload: b"bad",
          qos: QoS1,
          packet_id: Some(id),
          dup: false,
          retain: false,
        })
      1 =>
        Subscribe({
          packet_id: id,
          subscriptions: [{ topic_filter: "#", requested_qos: QoS2 }],
        })
      _ => Unsubscribe({ packet_id: id, topic_filters: ["#"] })
    }
    assert_eq(receive(rt, cid(1L), packet, 5L), [
      CloseTransport({ connection_id: cid(1L), reason: ProtocolError }),
    ])
    assert_eq(rt.broker_state().inbound_qos2_count(), 1)
    assert_eq(rt.check_invariants(), Ok(()))
  }
}

///|
test "qos2 takeover preserves state rejects stale acks and clean reconnect resets it" {
  let rt = runtime()
  persistent_connect(rt, cid(1L), "owner", false)
  q2_sub(rt, cid(1L))
  let first = receive(rt, cid(1L), q2_publish(1), 3L)
  let outgoing = match first[1] {
    SendPacket({ packet: Publish(p), .. }) => p.packet_id.unwrap()
    _ => fail("publish")
  }
  open(rt, cid(2L), 4L)
  let takeover = receive(
    rt,
    cid(2L),
    connect_packet("owner", clean_session=false),
    5L,
  )
  assert_eq(takeover.length(), 3)
  assert_eq(receive(rt, cid(1L), Pubrec(outgoing), 6L), [])
  assert_eq(
    rt.broker_state().phase_count(@session.OutboundPhase::AwaitPubrec),
    1,
  )
  assert_eq(receive(rt, cid(2L), q2_publish(1, dup=true), 7L).length(), 1)
  open(rt, cid(3L), 8L)
  let clean = receive(rt, cid(3L), connect_packet("owner"), 9L)
  assert_eq(clean.length(), 2)
  assert_eq(rt.broker_state().inbound_qos2_count(), 0)
  assert_eq(rt.broker_state().inflight_count(), 0)
  assert_eq(rt.check_invariants(), Ok(()))
}

///|
test "qos2 acl drop completes handshake and preconnect packets cannot create state" {
  let rt = runtime()
  open(rt, cid(1L), 0L)
  assert_eq(receive(rt, cid(1L), q2_publish(1), 1L), [
    CloseTransport({ connection_id: cid(1L), reason: ProtocolError }),
  ])
  persistent_connect(rt, cid(2L), "denied", false)
  let id = @protocol.PacketId::new(2).unwrap()
  for dup in [false, true] {
    assert_eq(
      receive(rt, cid(2L), q2_publish(2, topic="$SYS/forged", dup~), 3L),
      [SendPacket({ connection_id: cid(2L), packet: Pubrec(id) })],
    )
  }
  assert_eq(rt.metrics().acl_denials(), 1L)
  assert_eq(rt.broker_state().retained_count(), 0)
  assert_eq(rt.broker_state().inbound_qos2_count(), 1)
  assert_eq(receive(rt, cid(2L), Pubrel(id), 4L), [
    SendPacket({ connection_id: cid(2L), packet: Pubcomp(id) }),
  ])
  assert_eq(rt.check_invariants(), Ok(()))
}

///|
test "qos2 will routes once on eof keepalive and takeover and is suppressed on orderly exits" {
  for
    reason in [
      CloseReason::PeerEof,
      KeepAliveTimeout,
      ClientTakeover,
      NormalDisconnect,
      ServerShutdown,
    ] {
    let rt = runtime()
    connect(rt, cid(1L), "observer")
    q2_sub(rt, cid(1L))
    open(rt, cid(2L), 0L)
    ignore(
      receive(
        rt,
        cid(2L),
        connect_packet(
          "will",
          will=Some({
            topic: "q2/will",
            payload: b"offline",
            qos: QoS2,
            retain: true,
          }),
        ),
        1L,
      ),
    )
    let actions = rt.apply(
      TransportClosed({ connection_id: cid(2L), reason, observed_at_ms: 10L }),
    )
    let count = actions
      .filter(action => {
        action is SendPacket({ packet: Publish({ qos: QoS2, .. }), .. })
      })
      .length()
    assert_eq(
      count,
      if reason == NormalDisconnect || reason == ServerShutdown {
        0
      } else {
        1
      },
    )
    assert_eq(
      rt.apply(
        TransportClosed({ connection_id: cid(2L), reason, observed_at_ms: 11L }),
      ),
      [],
    )
    assert_eq(rt.broker_state().inbound_qos2_count(), 0)
    assert_eq(rt.check_invariants(), Ok(()))
  }
}
