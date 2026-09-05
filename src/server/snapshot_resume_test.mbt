///|
test "restored broker state resumes before accept" {
  let config = runtime_config()
  let saved : @router.BrokerSnapshotV3 = {
    version: 1,
    sessions: [
      {
        client_id: "restored",
        owner_principal: "legacy-anonymous",
        detached_at_ms: 0L,
        next_packet_id: 8,
        subscriptions: [{ filter: "restored/#", qos: 1 }],
        inbound_qos2: [],
        inflight: [
          {
            packet_id: 7,
            phase: 1,
            message: Some({
              topic: "restored/value",
              payload: b"saved",
              retain: false,
              qos: 1,
            }),
          },
        ],
        pending: [],
      },
    ],
    retained: [],
  }
  let initial = @router.BrokerState::from_snapshot(
    config.broker_config(),
    saved,
  ).unwrap()
  let rt = BrokerRuntime::new(config, initial)
  let id = cid(201L)
  open(rt, id, 0L)
  let actions = receive(
    rt,
    id,
    connect_packet("restored", clean_session=false),
    1L,
  )
  assert_eq(
    actions[0],
    SendPacket({
      connection_id: id,
      packet: Connack({ session_present: true, return_code: Accepted }),
    }),
  )
  match actions[1] {
    SendPacket({ packet: Publish(packet), .. }) => {
      assert_eq(packet.packet_id, Some(@protocol.PacketId::new(7).unwrap()))
      assert_true(packet.dup)
      assert_eq(packet.payload, b"saved")
    }
    _ => fail("restored inflight must replay after accepted CONNACK")
  }
  assert_eq(rt.check_invariants(), Ok(()))
}
