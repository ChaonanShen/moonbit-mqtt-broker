///|
test "C-T06 MQTT5 assigned client ID uses 16 bytes and four collision attempts" {
  let bytes = Bytes::make(16, 0xab)
  let id = mqtt5_assign_id_with_source(() => Some(bytes), _ => false).unwrap()
  assert_eq(id, "mb5-abababababababababababababababab")
  let mut attempts = 0
  let collision = mqtt5_assign_id_with_source(
    () => {
      attempts += 1
      Some(bytes)
    },
    _ => true,
  )
  assert_eq(collision, None)
  assert_eq(attempts, 4)
  assert_eq(mqtt5_assign_id_with_source(() => None, _ => false), None)
  assert_eq(mqtt5_assign_id_with_source(() => Some(b"short"), _ => false), None)
}

///|
test "C-T06 native random identifier has fixed format" {
  let id = mqtt5_assign_id(_ => false)
  if id is Some(value) {
    assert_eq(value.length(), 36)
    assert_true(value.has_prefix("mb5-"))
  }
}
