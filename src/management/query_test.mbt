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

///|
test "query parser accepts bounded allowlisted filters and canonical IDs" {
  let spec = parse_read_query(
    "/v1/sessions?mode=persistent&attached=false&limit=7", "reader", 50, 100,
  ).unwrap()
  assert_eq(spec.kind, Sessions)
  assert_eq(spec.limit, 7)
  assert_eq(spec.filters, "attached=false&mode=persistent")
  assert_eq(
    parse_read_query("/v1/connections/42", "reader", 50, 100).unwrap().target,
    "42",
  )
  assert_eq(
    parse_read_query("/v1/sessions/5/subscriptions", "reader", 50, 100).unwrap().kind,
    Subscriptions,
  )
}

///|
test "query parser rejects aliases duplicate and unknown parameters" {
  for
    path in [
      "/v1/connections/01", "/v1/connections/0", "/v1/sessions/%31", "/v1/sessions/1?limit=1&limit=2",
      "/v1/retained?phase=active", "/v1/sessions?mode=other", "/v1/connections?limit=101",
      "/v1/sessions?cursor=bad", "/v1/listeners?limit=1", "/v1/sessions?",
    ] {
    assert_true(parse_read_query(path, "reader", 50, 100) is Err(_))
  }
}

///|
test "optional B fields encode scalar or null, never singleton arrays" {
  assert_eq(optional_string_json(Some("client")).stringify(), "\"client\"")
  assert_eq(optional_string_json(None).stringify(), "null")
  assert_eq(optional_decimal_json(Some(7L)).stringify(), "\"7\"")
  assert_eq(optional_decimal_json(None).stringify(), "null")
}
