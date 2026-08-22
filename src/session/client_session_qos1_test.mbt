///|
fn qos1_client(value : String) -> ClientId {
  ClientId::new(value).unwrap()
}

///|
fn qos1_message(value : String) -> SessionMessage {
  SessionMessage::new(
    @topic.TopicName::new("session/qos1").unwrap(),
    @utf8.encode(value),
    false,
  )
}

///|
test "outbound qos1 remains inflight until puback" {
  let session = ClientSession::new(qos1_client("client"), mode=Persistent)
  let limits = SessionLimits::new(1, 2).unwrap()
  let first = match session.stage(qos1_message("first"), limits).unwrap() {
    SendNow(delivery) => delivery
    _ => fail("attached session must send first message")
  }
  assert_false(first.dup)
  assert_eq(session.inflight_count(), 1)
  assert_eq(
    session.ack(SessionPacketId::new(999).unwrap(), limits),
    Ok(SessionAck::UnknownPacketId),
  )
  assert_eq(session.inflight_count(), 1)
  assert_eq(session.ack(first.packet_id, limits), Ok(Acknowledged([])))
  assert_eq(session.inflight_count(), 0)
}

///|
test "puback promotes pending qos1 in fifo order" {
  let session = ClientSession::new(qos1_client("fifo"), mode=Persistent)
  let limits = SessionLimits::new(1, 2).unwrap()
  let first = match session.stage(qos1_message("first"), limits).unwrap() {
    SendNow(delivery) => delivery
    _ => fail("first message must be inflight")
  }
  assert_eq(session.stage(qos1_message("second"), limits), Ok(Queued))
  assert_eq(session.stage(qos1_message("third"), limits), Ok(Queued))
  let promoted = match session.ack(first.packet_id, limits).unwrap() {
    Acknowledged(value) => value
    _ => fail("matching PUBACK must be acknowledged")
  }
  assert_eq(promoted.length(), 1)
  assert_eq(promoted[0].message.payload, b"second")
  let next = match session.ack(promoted[0].packet_id, limits).unwrap() {
    Acknowledged(value) => value
    _ => fail("matching PUBACK must promote third message")
  }
  assert_eq(next[0].message.payload, b"third")
}

///|
test "unacknowledged qos1 replay keeps packet id and sets dup" {
  let session = ClientSession::new(qos1_client("replay"), mode=Persistent)
  let limits = SessionLimits::new(2, 2).unwrap()
  let original = match session.stage(qos1_message("saved"), limits).unwrap() {
    SendNow(delivery) => delivery
    _ => fail("message must be sent")
  }
  session.detach()
  let replay = session.attach(limits).unwrap()
  assert_eq(replay.length(), 1)
  assert_eq(replay[0].packet_id, original.packet_id)
  assert_true(replay[0].dup)
  assert_eq(replay[0].message.payload, b"saved")
  assert_eq(session.check_invariants(limits), Ok(()))
}

///|
test "detached session queues defensively copied qos1 payload" {
  let session = ClientSession::new(
    qos1_client("offline"),
    mode=Persistent,
    attached=false,
  )
  let limits = SessionLimits::new(1, 1).unwrap()
  let source : Array[Byte] = [0x71, 0x75, 0x65, 0x75, 0x65, 0x64]
  let payload = Bytes::from_array(source)
  assert_eq(
    session.stage(
      SessionMessage::new(
        @topic.TopicName::new("offline/qos1").unwrap(),
        payload,
        false,
      ),
      limits,
    ),
    Ok(Queued),
  )
  source[0] = 0x58
  assert_eq(session.pending()[0].payload, b"queued")
  assert_true(
    session.stage(qos1_message("overflow"), limits)
    is Err(PendingLimitReached(_)),
  )
}
