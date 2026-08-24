///|
test "crc32 matches ieee standard vector" {
  assert_eq(crc32(b"123456789"), 0xcbf43926U)
  assert_eq(crc32(b""), 0U)
}
