///|
test "C-T14 MQTT5 negative PUBREC terminates without PUBREL or promotion" {
  let session = ClientSession::new(
    ClientId::new("v5-negative").unwrap(),
    mode=Persistent,
  )
  let limits = SessionLimits::new(1, 2).unwrap()
  let first = q2_stage(session, q2_message("first"), limits)
  assert_eq(session.stage(q2_message("pending", qos=QoS1), limits), Ok(Queued))
  assert_eq(
    session.apply_v5_outbound_ack(first.packet_id, V5Pubrec, true),
    Ok(V5Terminal),
  )
  assert_eq(session.inflight_count(), 0)
  assert_eq(session.pending_count(), 1)
  assert_eq(
    session.apply_v5_outbound_ack(first.packet_id, V5Pubrec, false),
    Ok(V5UnknownPacketId),
  )
  assert_eq(session.check_invariants(limits), Ok(()))
}

///|
test "C-T14 MQTT5 successful PUBREC holds exchange until PUBCOMP" {
  let session = ClientSession::new(
    ClientId::new("v5-positive").unwrap(),
    mode=Persistent,
  )
  let limits = SessionLimits::new(1, 2).unwrap()
  let first = q2_stage(session, q2_message("first"), limits)
  assert_eq(
    session.apply_v5_outbound_ack(first.packet_id, V5Puback, false),
    Err(InvalidAcknowledgement),
  )
  assert_eq(
    session.apply_v5_outbound_ack(first.packet_id, V5Pubrec, false),
    Ok(V5SendPubrel),
  )
  assert_eq(session.inflight_count(), 1)
  assert_eq(session.inflight()[0].phase, AwaitPubcomp)
  assert_eq(
    session.apply_v5_outbound_ack(first.packet_id, V5Pubcomp, false),
    Ok(V5Terminal),
  )
  assert_eq(session.inflight_count(), 0)
  assert_eq(session.check_invariants(limits), Ok(()))
}
