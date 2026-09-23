///|
fn test_fixed_bytes(value : FixedArray[Byte]) -> Bytes {
  let bytes : Array[Byte] = []
  for byte in value {
    bytes.push(byte)
  }
  Bytes::from_array(bytes)
}

///|
test "management SHA256 matches independent abc vector" {
  assert_true(initialize() is Ok(_))
  let digest = sha256(b"abc").unwrap()
  assert_eq(
    test_fixed_bytes(digest),
    Bytes::from_array([
      0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d,
      0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10,
      0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    ]),
  )
}

///|
test "management domain-separated token vector matches sha256sum" {
  assert_true(initialize() is Ok(_))
  let token = "moonbit-mqtt-broker/admin/v1:spike-token." +
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  let digest = sha256(@utf8.encode(token)).unwrap()
  assert_eq(
    test_fixed_bytes(digest),
    Bytes::from_array([
      0xdc, 0x21, 0x1f, 0x32, 0x14, 0xc8, 0xdc, 0x9c, 0xcf, 0xdf, 0x0c, 0x2f, 0x28,
      0x35, 0xed, 0x51, 0x5f, 0xc2, 0xe0, 0x32, 0xd9, 0x12, 0x93, 0x4e, 0x1d, 0x70,
      0x0f, 0x83, 0x74, 0x74, 0x72, 0x36,
    ]),
  )
}

///|
test "management hash length cap and constant-time 32 byte comparison" {
  assert_true(initialize() is Ok(_))
  assert_true(sha256(test_fixed_bytes(FixedArray::make(128, 65))) is Ok(_))
  assert_true(sha256(test_fixed_bytes(FixedArray::make(129, 65))) is Err(_))
  let digest = sha256(b"abc").unwrap()
  let same = sha256(b"abc").unwrap()
  let other = sha256(b"abd").unwrap()
  assert_true(equal32(digest, same))
  assert_false(equal32(digest, other))
  assert_false(equal32(digest, FixedArray::make(31, 0)))
}

///|
test "management entropy has bounded length and returns fresh bytes" {
  let first = secure_random(32).unwrap()
  let second = secure_random(32).unwrap()
  assert_false(test_fixed_bytes(first) == test_fixed_bytes(second))
  assert_true(secure_random(0) is Err(_))
  assert_true(secure_random(33) is Err(_))
}
