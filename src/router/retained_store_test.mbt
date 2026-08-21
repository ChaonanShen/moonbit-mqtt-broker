///|
fn retained_topic(value : String) -> @topic.TopicName {
  @topic.TopicName::new(value).unwrap()
}

///|
fn retained_filter(value : String) -> @topic.TopicFilter {
  @topic.TopicFilter::new(value).unwrap()
}

///|
test "retained store bounds new topics but permits replacement and deletion" {
  let store = RetainedStore::new()
  let a = retained_topic("a")
  assert_true(store.put(a, b"one", @session.DeliveryQoS::QoS0, 1))
  assert_false(
    store.put(retained_topic("b"), b"two", @session.DeliveryQoS::QoS0, 1),
  )
  assert_true(store.put(a, b"new", @session.DeliveryQoS::QoS1, 1))
  assert_eq(
    store.get(a),
    Some({ topic: a, payload: b"new", qos: @session.DeliveryQoS::QoS1 }),
  )
  store.remove(a)
  assert_eq(store.count(), 0)
  assert_eq(store.matching([retained_filter("#")]), [])
}

///|
test "retained replay ordering ignores insertion order" {
  let first = RetainedStore::new()
  for name in ["z/topic", "é/topic", "a/topic", "😀/topic", "m/topic"] {
    assert_true(
      first.put(retained_topic(name), b"x", @session.DeliveryQoS::QoS0, 8),
    )
  }
  let second = RetainedStore::new()
  for name in ["m/topic", "😀/topic", "a/topic", "z/topic", "é/topic"] {
    assert_true(
      second.put(retained_topic(name), b"x", @session.DeliveryQoS::QoS0, 8),
    )
  }
  let expected = ["a/topic", "m/topic", "z/topic", "é/topic", "😀/topic"]
  let filters = [retained_filter("#")]
  assert_eq(
    first.matching(filters).map(fn(item) { item.topic.value() }),
    expected,
  )
  assert_eq(
    second.matching(filters).map(fn(item) { item.topic.value() }),
    expected,
  )
}
