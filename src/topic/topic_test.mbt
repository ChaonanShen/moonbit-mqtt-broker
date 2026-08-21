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

///|
test "topic utf8 length boundaries accept one and 65535 bytes" {
  assert_true(TopicName::new("a") is Ok(_))
  assert_true(TopicFilter::new("+") is Ok(_))
  assert_true(TopicName::new("a".repeat(65535)) is Ok(_))
  assert_true(TopicFilter::new("a".repeat(65535)) is Ok(_))
  assert_eq(
    TopicFilter::new("é".repeat(32768)),
    Err(TopicError::EncodedLengthExceeded(65536)),
  )
}

///|
test "topic wildcard validation rejects every partial wildcard form" {
  for invalid in ["a+", "+a"] {
    assert_eq(
      TopicFilter::new(invalid),
      Err(TopicError::InvalidSingleLevelWildcard),
    )
  }
  for invalid in ["a/#/b", "a#", "##"] {
    assert_eq(
      TopicFilter::new(invalid),
      Err(TopicError::InvalidMultiLevelWildcard),
    )
  }
}

///|
test "topic names preserve empty levels and original unicode" {
  for valid in ["/", "/a", "a/", "a//b", "é", "e\u{0301}"] {
    assert_true(TopicName::new(valid) is Ok(_))
  }
  assert_false(
    TopicName::new("é").unwrap() == TopicName::new("e\u{0301}").unwrap(),
  )
}

///|
test "topic names are case sensitive" {
  assert_false(
    TopicName::new("Topic").unwrap() == TopicName::new("topic").unwrap(),
  )
}
