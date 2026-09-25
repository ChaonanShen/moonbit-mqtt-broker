///|
test "C-T21 MQTT5 remaining expiry rounds up without restarting the timer" {
  let metadata : @session.MessageMetadata = {
    ..@session.MessageMetadata::empty(),
    expiry: Some(@session.Deadline::new(1000L, 1000L, 1501L).unwrap()),
  }
  assert_eq(mqtt5_message_properties(metadata, 1001L)[0], {
    id: 0x02,
    value: @protocol.FourByteValue(2U),
  })
  assert_eq(mqtt5_message_properties(metadata, 1501L)[0], {
    id: 0x02,
    value: @protocol.FourByteValue(1U),
  })
  assert_eq(mqtt5_message_properties(metadata, 2501L)[0], {
    id: 0x02,
    value: @protocol.FourByteValue(0U),
  })
}
