///|
fn parsed_head(
  bytes : Bytes,
  max_bytes? : Int = 4096,
  max_count? : Int = 32,
) -> HttpRequestHead? {
  let parser = HttpParser::new(max_bytes, max_count)
  match parser.feed(bytes) {
    Complete(head, _) => Some(head)
    _ => None
  }
}

///|
test "HTTP header splits at every byte position with identical result" {
  let value = "GET /health/live HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\n\r\n"
  let full = @utf8.encode(value)
  let reference = parsed_head(full).unwrap()
  for split in 0..<full.length() {
    let parser = HttpParser::new(4096, 32)
    let first = @utf8.encode(value[:split].to_owned())
    let second = @utf8.encode(value[split:].to_owned())
    match parser.feed(first) {
      NeedMore => ()
      _ => fail("premature completion")
    }
    match parser.feed(second) {
      Complete(head, consumed) => {
        assert_eq(head.target, reference.target)
        assert_eq(head.method_name, reference.method_name)
        assert_eq(head.headers.length(), reference.headers.length())
        assert_eq(consumed, second.length())
      }
      _ => fail("split header was not completed")
    }
  }
}

///|
test "HTTP parser also accepts the head byte by byte" {
  let value = @utf8.encode(
    "GET /v1/status HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test\r\n\r\n",
  )
  let parser = HttpParser::new(4096, 32)
  for index in 0..<value.length() {
    match parser.feed(Bytes::from_array([value[index]])) {
      NeedMore => assert_true(index + 1 < value.length())
      Complete(head, consumed) => {
        assert_eq(index + 1, value.length())
        assert_eq(consumed, 1)
        assert_eq(head.target, "/v1/status")
      }
      _ => fail("valid byte-wise header rejected")
    }
  }
}

///|
test "HTTP parser returns exact suffix offset and never processes a second request" {
  let value = "GET /metrics?format=text HTTP/1.1\r\nHost: localhost\r\n\r\n"
  let parser = HttpParser::new(4096, 32)
  match parser.feed(@utf8.encode(value + "NEXT")) {
    Complete(head, consumed) => {
      assert_eq(head.target, "/metrics?format=text")
      assert_eq(consumed, @utf8.encode(value).length())
    }
    _ => fail("expected one head")
  }
  assert_true(parser.feed(b"GET /second HTTP/1.1") is Reject(_))
}

///|
test "HTTP rejects ambiguous request framing and dangerous bytes" {
  for
    value in [
      "GET / HTTP/1.1\nHost: x\n\n", "GET / HTTP/1.1\rHost: x\r\n\r\n", "GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n",
      "GET / HTTP/1.1\r\nHost : x\r\n\r\n", "GET / HTTP/1.1\r\n Host: x\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: x\r\nAuthorization: a\r\nAuthorization: b\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n", "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 2147483648\r\n\r\n",
      "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: +1\r\n\r\n", "GET /foo#bar HTTP/1.1\r\nHost: x\r\n\r\n",
      "GET http://x/ HTTP/1.1\r\nHost: x\r\n\r\n", "GET / HTTP/1.0\r\nHost: x\r\n\r\n",
    ] {
    let parser = HttpParser::new(4096, 32)
    assert_true(parser.feed(@utf8.encode(value)) is Reject(_))
  }
  let parser = HttpParser::new(4096, 32)
  assert_true(parser.feed(Bytes::from_array([0xff])) is Reject(_))
}

///|
test "HTTP parser enforces total, field and header-count limits" {
  let valid = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
  let length = @utf8.encode(valid).length()
  assert_true(
    HttpParser::new(length, 32).feed(@utf8.encode(valid)) is Complete(_, _),
  )
  assert_true(
    HttpParser::new(length - 1, 32).feed(@utf8.encode(valid))
    is Reject(HeaderTooLarge),
  )
  assert_true(
    HttpParser::new(4096, 1).feed(
      @utf8.encode("GET / HTTP/1.1\r\nHost: x\r\nX-Test: yes\r\n\r\n"),
    )
    is Reject(TooManyHeaders),
  )
  let early = HttpParser::new(4096, 1)
  assert_true(
    early.feed(@utf8.encode("GET / HTTP/1.1\r\nHost: x\r\nX-Test: yes\r\n"))
    is Reject(TooManyHeaders),
  )
  let max_field = "GET / HTTP/1.1\r\nHost: x\r\nX:" +
    "a".repeat(2046) +
    "\r\n\r\n"
  assert_true(
    HttpParser::new(4096, 32).feed(@utf8.encode(max_field)) is Complete(_, _),
  )
  assert_true(
    HttpParser::new(4096, 32).feed(
      @utf8.encode(
        "GET / HTTP/1.1\r\nHost: x\r\nX:" + "a".repeat(2047) + "\r\n\r\n",
      ),
    )
    is Reject(BadRequest),
  )
  assert_true(
    HttpParser::new(4096, 32).feed(
      @utf8.encode(
        "GET / HTTP/1.1\r\nHost: x\r\nX-Long: " + "a".repeat(2048) + "\r\n\r\n",
      ),
    )
    is Reject(BadRequest),
  )
  assert_true(
    HttpParser::new(4096, 32).feed(
      @utf8.encode("GET /" + "a".repeat(1023) + " HTTP/1.1\r\nHost: x\r\n\r\n"),
    )
    is Complete(_, _),
  )
  assert_true(
    HttpParser::new(4096, 32).feed(
      @utf8.encode("GET /" + "a".repeat(1024) + " HTTP/1.1\r\nHost: x\r\n\r\n"),
    )
    is Reject(BadRequest),
  )
}

///|
test "HTTP parser preserves valid colon values and parsed zero length" {
  let head = parsed_head(
    @utf8.encode(
      "GET / HTTP/1.1\r\nHost: x\r\nOrigin: https://example.test:8443\r\nContent-Length: 00\r\n\r\n",
    ),
  ).unwrap()
  assert_eq(head.headers.length(), 3)
  assert_eq(head.headers[1].value, "https://example.test:8443")
  assert_eq(head.content_length, Some(0))
}
