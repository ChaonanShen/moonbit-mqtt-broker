///|
test "C-T10 indexed expiry heap updates and removes without stale nodes" {
  let heap = ExpiryScheduler::new(3, 512L)
  assert_true(heap.set("retained/a", 300L, 1L))
  assert_true(heap.set("will/2", 200L, 1L))
  assert_true(heap.set("pending/1", 100L, 1L))
  assert_false(heap.set("extra", 50L, 1L))
  assert_eq(heap.peek_due(99L), None)
  assert_eq(heap.peek_due(100L).unwrap().key, "pending/1")
  assert_true(heap.set("pending/1", 400L, 2L))
  assert_eq(heap.length(), 3)
  assert_eq(heap.peek_due(200L).unwrap().key, "will/2")
  assert_true(heap.remove("will/2"))
  assert_eq(heap.peek_due(300L).unwrap().key, "retained/a")
  assert_false(heap.remove("will/2"))
  assert_true(heap.check_invariants())
  let clone = heap.copy()
  assert_true(clone.remove("retained/a"))
  assert_eq(heap.length(), 2)
  assert_eq(clone.length(), 1)
  assert_true(clone.check_invariants())
}

///|
test "C-T28 pending expiry tracks stable delivery identity through copy and deletion" {
  let client = ClientId::new("pending-index").unwrap()
  let session = ClientSession::new(client, mode=Persistent, attached=false)
  let limits = SessionLimits::new(2, 4).unwrap()
  let metadata : MessageMetadata = {
    ..MessageMetadata::empty(),
    expiry: Some(Deadline::new(1000L, 1000L, 2000L).unwrap()),
  }
  let message = SessionMessage::new(
    @topic.TopicName::new("pending/index").unwrap(),
    b"body",
    false,
    metadata~,
    delivery_id=42L,
  )
  assert_eq(session.stage(message, limits), Ok(Queued))
  assert_eq(session.next_expired_pending_id(2999L), None)
  assert_eq(session.next_expired_pending_id(3000L), Some(42L))
  let copy = session.copy()
  let expected = copy.pending_item_reference(0).unwrap()
  let remaining = copy.pending_without_item_for_policy(0)
  assert_true(copy.discard_pending_item_prepared(0, expected, remaining))
  assert_eq(copy.next_expired_pending_id(3000L), None)
  assert_eq(session.next_expired_pending_id(3000L), Some(42L))
  assert_eq(copy.check_invariants(limits), Ok(()))
  assert_eq(session.check_invariants(limits), Ok(()))
}
