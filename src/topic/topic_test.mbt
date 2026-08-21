///|
test "topic names and filters validate MQTT wildcard rules" {
  assert_eq(TopicName::new(""), Err(TopicError::EmptyTopicName))
  assert_eq(TopicFilter::new(""), Err(TopicError::EmptyTopicFilter))
  assert_eq(TopicName::new("a/+"), Err(TopicError::WildcardInTopicName))
  assert_eq(TopicFilter::new("a+"), Err(TopicError::InvalidSingleLevelWildcard))
  assert_eq(
    TopicFilter::new("a/#/b"),
    Err(TopicError::InvalidMultiLevelWildcard),
  )
  assert_eq(TopicFilter::new("a/#").map(fn(_) { true }), Ok(true))
  assert_eq(TopicFilter::new("a/+").map(fn(_) { true }), Ok(true))
}

///|
test "topic validation uses utf8 byte length and rejects nul" {
  let valid = "a".repeat(65535)
  assert_true(TopicName::new(valid) is Ok(_))
  let too_long = "é".repeat(32768)
  assert_eq(
    TopicName::new(too_long),
    Err(TopicError::EncodedLengthExceeded(65536)),
  )
  assert_eq(TopicName::new("a\u{0000}b"), Err(TopicError::NullCharacter))
}
