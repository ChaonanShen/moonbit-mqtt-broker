///|
fn client(value : String) -> @session.ClientId {
  @session.ClientId::new(value).unwrap()
}

///|
fn filter(value : String) -> @topic.TopicFilter {
  @topic.TopicFilter::new(value).unwrap()
}

///|
fn topic(value : String) -> @topic.TopicName {
  @topic.TopicName::new(value).unwrap()
}

///|
test "subscription index is bidirectional and merges matching qos" {
  let index = SubscriptionIndex::new()
  let alice = client("alice")
  let bob = client("bob")
  assert_true(index.put(alice, filter("a/#"), @session.DeliveryQoS::QoS0))
  assert_true(index.put(alice, filter("a/b"), @session.DeliveryQoS::QoS1))
  assert_true(index.put(bob, filter("a/+"), @session.DeliveryQoS::QoS0))
  assert_false(index.put(alice, filter("a/#"), @session.DeliveryQoS::QoS1))
  assert_eq(index.subscription_count(), 3)
  assert_eq(index.subscription_count_for(alice), 2)
  assert_eq(index.matches(topic("a/b")), [
    { client_id: alice, qos: @session.DeliveryQoS::QoS1 },
    { client_id: bob, qos: @session.DeliveryQoS::QoS0 },
  ])
  assert_true(index.check_invariants())
  assert_true(index.remove(alice, filter("a/#")))
  assert_eq(index.remove_all(alice), 1)
  assert_eq(index.subscription_count(), 1)
  assert_true(index.check_invariants())
}

///|
test "action ordering ignores insertion order" {
  let ordered_topic = topic("ordered")
  let ordered_filter = filter("ordered")
  let first = SubscriptionIndex::new()
  for name in ["charlie", "éclair", "alice", "😀", "bob"] {
    ignore(first.put(client(name), ordered_filter, @session.DeliveryQoS::QoS0))
  }
  let second = SubscriptionIndex::new()
  for name in ["bob", "😀", "alice", "charlie", "éclair"] {
    ignore(second.put(client(name), ordered_filter, @session.DeliveryQoS::QoS0))
  }
  let expected = ["alice", "bob", "charlie", "éclair", "😀"]
  assert_eq(
    first.matches(ordered_topic).map(fn(item) { item.client_id.value() }),
    expected,
  )
  assert_eq(
    second.matches(ordered_topic).map(fn(item) { item.client_id.value() }),
    expected,
  )
}
