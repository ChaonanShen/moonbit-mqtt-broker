///|
test "command key and strong etag reject ambiguous forms" {
  let boot = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let valid = "\"" + boot + ":s:12:3\""
  assert_eq(parse_strong_etag(valid, "s").unwrap().lifecycle_version, Some(3L))
  for
    value in [
      "W/" + valid,
      "*",
      "\"" + boot + ":s:12:3\",\"other\"",
      "\"" + boot + ":s:012:3\"",
      "\"" + boot + ":s:12:0\"",
      "\"" + boot + ":c:12\"",
    ] {
    assert_true(parse_strong_etag(value, "s") is Err(_))
  }
  assert_true(valid_idempotency_key("Abcdefghijklmn_0"))
  for key in ["short", "abcdefghijklmno!", "abcdefghijklmnoé"] {
    assert_false(valid_idempotency_key(key))
  }
}

///|
test "command paths are precise and normalize method target and etag" {
  let boot = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let tag = "\"" + boot + ":s:12:3\""
  let spec = parse_command(
    "DELETE", "/v1/sessions/12", tag, "Abcdefghijklmn_0", "actor",
  ).unwrap()
  assert_eq(spec.kind, DeleteSession)
  assert_eq(spec.normalized(), "DELETE:/v1/sessions/12:" + tag)
  assert_true(
    parse_command("DELETE", "/v1/sessions/13", tag, "Abcdefghijklmn_0", "actor")
    is Err(InvalidIfMatch),
  )
  assert_true(
    parse_command(
      "DELETE", "/v1/sessions/%31%32", tag, "Abcdefghijklmn_0", "actor",
    )
    is Err(InvalidCommandPath),
  )
}
