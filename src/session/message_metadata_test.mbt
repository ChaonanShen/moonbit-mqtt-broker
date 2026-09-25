///|
test "C-T13 MQTT5 message metadata survives session copy and costs bytes" {
  let topic = @topic.TopicName::new("sensor/a").unwrap()
  let response = @topic.TopicName::new("reply/a").unwrap()
  let owner = ClientId::new("sender").unwrap()
  let metadata : MessageMetadata = {
    payload_format: Some(1),
    content_type: Some("text/plain"),
    response_topic: Some(response),
    correlation_data: Some(b"\x00\xff"),
    user_properties: [("k", "v1"), ("k", "v2")],
    publisher_client_id: Some(owner),
    expiry: Some(Deadline::from_seconds(0L, 100L, 10U).unwrap()),
  }
  let with_metadata = SessionMessage::new(topic, b"payload", false, metadata~)
  let without = SessionMessage::new(topic, b"payload", false)
  assert_true(with_metadata.cost() > without.cost())
  assert_eq(with_metadata.copy(), with_metadata)
  assert_eq(with_metadata.metadata.user_properties.length(), 2)
  assert_eq(with_metadata.metadata.correlation_data, Some(b"\x00\xff"))
}
