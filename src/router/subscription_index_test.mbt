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
