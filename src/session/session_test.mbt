///|
test "client id and delivery qos are constrained values" {
  assert_eq(ClientId::new(""), Err(SessionError::EmptyClientId))
  assert_eq(ClientId::new("a\u{0000}"), Err(SessionError::NullCharacter))
  assert_eq(min_qos(DeliveryQoS::QoS0, DeliveryQoS::QoS1), DeliveryQoS::QoS0)
  assert_eq(max_qos(DeliveryQoS::QoS0, DeliveryQoS::QoS1), DeliveryQoS::QoS1)
}
