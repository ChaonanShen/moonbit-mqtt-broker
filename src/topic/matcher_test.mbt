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
