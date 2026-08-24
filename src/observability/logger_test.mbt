///|
test "json logs have stable fields and escape untrusted values" {
  let logger = Logger::new(format=Json, minimum_level=Debug)
  let line = logger
    .render(
      LogRecord::new(
        123L,
        Warn,
        "acl_denied",
        message="safe summary",
        connection_id="7",
        client_id="quote\"client",
        principal="user:alice",
        peer="127.0.0.1:1234",
        reason="publish_write_denied",
        snapshot_revision="9",
      ),
    )
    .unwrap()
  let object : Map[String, String] = @json.from_json(@json.parse(line))
  assert_eq(object.get("timestamp_ms"), Some("123"))
  assert_eq(object.get("level"), Some("warn"))
  assert_eq(object.get("event"), Some("acl_denied"))
  assert_eq(object.get("connection_id"), Some("7"))
  assert_eq(object.get("client_id"), Some("quote\"client"))
  assert_eq(object.get("principal"), Some("user:alice"))
  assert_eq(object.get("peer"), Some("127.0.0.1:1234"))
  assert_eq(object.get("reason"), Some("publish_write_denied"))
  assert_eq(object.get("snapshot_revision"), Some("9"))
  assert_false(line.contains("password"))
  assert_false(line.contains("payload"))
}

///|
test "log levels filter and silent logger emits nothing" {
  let record = LogRecord::new(1L, Info, "event")
  assert_true(Logger::new(minimum_level=Info).render(record) is Some(_))
  assert_true(Logger::new(minimum_level=Warn).render(record) is None)
  assert_true(Logger::silent().render(record) is None)
}
