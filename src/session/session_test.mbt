///|
test "client id and delivery qos are constrained values" {
  assert_eq(ClientId::new(""), Err(SessionError::EmptyClientId))
  assert_eq(ClientId::new("a\u{0000}"), Err(SessionError::NullCharacter))
  assert_eq(min_qos(DeliveryQoS::QoS0, DeliveryQoS::QoS1), DeliveryQoS::QoS0)
  assert_eq(max_qos(DeliveryQoS::QoS0, DeliveryQoS::QoS1), DeliveryQoS::QoS1)
}

///|
test "client id validates utf8 byte boundaries" {
  assert_true(ClientId::new("a") is Ok(_))
  assert_true(ClientId::new("a".repeat(65535)) is Ok(_))
  assert_eq(
    ClientId::new("é".repeat(32768)),
    Err(SessionError::EncodedLengthExceeded(65536)),
  )
}

///|
test "client session exposes only its validated identity" {
  let id = ClientId::new("client").unwrap()
  assert_eq(ClientSession::new(id).client_id(), id)
}
