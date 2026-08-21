///|
fn invariant_client(value : String) -> @session.ClientId {
  @session.ClientId::new(value).unwrap()
}

///|
fn invariant_filter(value : String) -> @topic.TopicFilter {
  @topic.TopicFilter::new(value).unwrap()
}

///|
fn valid_index() -> SubscriptionIndex {
  let index = SubscriptionIndex::new()
  ignore(
    index.put(
      invariant_client("client"),
      invariant_filter("a/#"),
      @session.DeliveryQoS::QoS0,
    ),
  )
  index
}

///|
test "subscription index rejects reverse-only corruption" {
  let index = valid_index()
  index.by_filter.remove(invariant_filter("a/#"))
  assert_false(index.check_invariants())
}

///|
test "subscription index rejects forward-only and qos corruption" {
  let forward_only = valid_index()
  forward_only.by_client.remove(invariant_client("client"))
  assert_false(forward_only.check_invariants())
  let qos_mismatch = valid_index()
  qos_mismatch.by_client
  .get(invariant_client("client"))
  .unwrap()
  .set(invariant_filter("a/#"), @session.DeliveryQoS::QoS1)
  assert_false(qos_mismatch.check_invariants())
}

///|
test "subscription index rejects empty buckets and incorrect counts" {
  let empty_forward = valid_index()
  empty_forward.by_filter.set(invariant_filter("empty"), Map([]))
  assert_false(empty_forward.check_invariants())
  let empty_reverse = valid_index()
  empty_reverse.by_client.set(invariant_client("empty"), Map([]))
  assert_false(empty_reverse.check_invariants())
  let wrong_count = valid_index()
  wrong_count.count = 2
  assert_false(wrong_count.check_invariants())
  wrong_count.count = -1
  assert_false(wrong_count.check_invariants())
}
