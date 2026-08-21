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
