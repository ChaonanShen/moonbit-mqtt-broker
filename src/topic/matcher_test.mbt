///|
fn name(value : String) -> TopicName {
  TopicName::new(value).unwrap()
}

///|
fn filter(value : String) -> TopicFilter {
  TopicFilter::new(value).unwrap()
}

///|
test "mqtt filters retain empty levels and honor dollar namespace" {
  assert_true(TopicFilter::new("a/+") is Ok(_))
  assert_true(filter("a/+").matches(name("a/")))
  assert_true(filter("a/#").matches(name("a")))
  assert_true(filter("a/#").matches(name("a//b")))
  assert_true(filter("/").matches(name("/")))
  assert_false(filter("#").matches(name("$SYS/status")))
  assert_false(filter("+/status").matches(name("$SYS/status")))
  assert_true(filter("$SYS/#").matches(name("$SYS/status")))
}

///|
fn reference_matches(filter_value : String, topic_value : String) -> Bool {
  let filter_levels = filter_value.split("/").to_array()
  let topic_levels = topic_value.split("/").to_array()
  if topic_value.has_prefix("$") &&
    (filter_levels[0] == "+" || filter_levels[0] == "#") {
    return false
  }
  let mut topic_index = 0
  for filter_level in filter_levels {
    if filter_level == "#" {
      return true
    }
    if topic_index >= topic_levels.length() {
      return false
    }
    if filter_level != "+" && filter_level != topic_levels[topic_index] {
      return false
    }
    topic_index = topic_index + 1
  }
  topic_index == topic_levels.length()
}

///|
test "matcher covers exact wildcard parent empty and system topics" {
  let cases = [
    ("a/b", "a/b", true),
    ("a/+", "a/", true),
    ("a/+", "a/b/c", false),
    ("a/#", "a", true),
    ("a/#", "a//b", true),
    ("/+/", "//", true),
    ("#", "$SYS/x", false),
    ("+/#", "$SYS/x", false),
    ("$SYS/#", "$SYS/x", true),
    ("A/#", "a/x", false),
  ]
  for item in cases {
    let (filter_value, topic_value, expected) = item
    assert_eq(filter(filter_value).matches(name(topic_value)), expected)
  }
}

///|
test "one thousand deterministic topic matches" {
  let filters = ["#", "+", "a/#", "a/+", "+/b", "a//+", "$SYS/#", "/#"]
  let topics = ["a", "b", "a/b", "a//c", "/", "/x", "$SYS/x", "A/b", "é/x"]
  for iteration in 0..<1000 {
    let filter_value = filters[(iteration * 17 + 3) % filters.length()]
    let topic_value = topics[(iteration * 31 + iteration / 7) % topics.length()]
    assert_eq(
      filter(filter_value).matches(name(topic_value)),
      reference_matches(filter_value, topic_value),
    )
  }
}
