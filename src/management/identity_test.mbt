///|
test "boot identities are random 128-bit lowercase hexadecimal" {
  let first = new_boot_id().unwrap()
  let second = new_boot_id().unwrap()
  assert_eq(first.length(), 32)
  assert_eq(second.length(), 32)
  assert_false(first == second)
  for ch in first {
    let code = ch.to_int()
    assert_true((code >= 48 && code <= 57) || (code >= 97 && code <= 102))
  }
}
