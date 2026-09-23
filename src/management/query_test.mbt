///|
test "query schema fixture uses string IDs and per-page consistency" {
  let page : QueryEnvelope = {
    boot_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    observed_at_ms: 1234567890123L,
    state_revision: 9007199254740993L,
    items: [],
    next_cursor: None,
  }
  let encoded = page.to_json().stringify()
  assert_true(encoded.contains("\"api_version\":\"1\""))
  assert_true(encoded.contains("\"state_revision\":\"9007199254740993\""))
  assert_true(encoded.contains("\"consistency\":\"per_page\""))
  assert_true(encoded.contains("\"next_cursor\":null"))
}

///|
test "lifecycle etag changes on epoch and instance replacement" {
  let boot = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let first = session_etag(boot, 1L, 1L)
  assert_eq(first, "\"" + boot + ":s:1:1\"")
  assert_true(first != session_etag(boot, 1L, 2L))
  assert_true(first != session_etag(boot, 2L, 1L))
  assert_true(first != session_etag("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 1L, 1L))
  assert_eq(connection_etag(boot, 7L), "\"" + boot + ":c:7\"")
}
