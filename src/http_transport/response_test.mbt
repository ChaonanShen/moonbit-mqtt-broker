///|
test "fixed HTTP response bytes and body Content-Length" {
  let encoded = encode_response(Ok, JsonBody, b"{\"ok\":true}", 65536).unwrap()
  let expected = @utf8.encode(
    "HTTP/1.1 200 OK\r\n" +
    "Content-Type: application/json\r\n" +
    "Content-Length: 11\r\n" +
    "Connection: close\r\n" +
    "Cache-Control: no-store\r\n\r\n" +
    "{\"ok\":true}",
  )
  assert_eq(encoded, expected)
}

///|
test "UTF-8 content length counts bytes rather than characters" {
  let body = @utf8.encode("{\"message\":\"你好\"}")
  let encoded = encode_response(Ok, JsonBody, body, 65536).unwrap()
  let prefix = @utf8.encode(
    "HTTP/1.1 200 OK\r\n" +
    "Content-Type: application/json\r\n" +
    "Content-Length: 20\r\n" +
    "Connection: close\r\n" +
    "Cache-Control: no-store\r\n\r\n",
  )
  assert_eq(encoded.length(), prefix.length() + 20)
  for index in 0..<prefix.length() {
    assert_eq(encoded[index], prefix[index])
  }
}

///|
test "401 and 405 add only their fixed security headers" {
  let unauthorized = encode_response(Unauthorized, JsonBody, b"{}", 2).unwrap()
  assert_eq(
    unauthorized,
    @utf8.encode(
      "HTTP/1.1 401 Unauthorized\r\n" +
      "Content-Type: application/json\r\n" +
      "Content-Length: 2\r\n" +
      "Connection: close\r\n" +
      "Cache-Control: no-store\r\n" +
      "WWW-Authenticate: Bearer\r\n\r\n{}",
    ),
  )
  let method_response = encode_response(
    MethodNotAllowed,
    JsonBody,
    b"{}",
    2,
    allow=AllowGet,
  ).unwrap()
  assert_eq(
    method_response,
    @utf8.encode(
      "HTTP/1.1 405 Method Not Allowed\r\n" +
      "Content-Type: application/json\r\n" +
      "Content-Length: 2\r\n" +
      "Connection: close\r\n" +
      "Cache-Control: no-store\r\n" +
      "Allow: GET\r\n\r\n{}",
    ),
  )
}

///|
test "Prometheus media type and exact body limit" {
  let body = b"# HELP x counter\nx 1\n"
  let encoded = encode_response(Ok, PrometheusBody, body, body.length()).unwrap()
  assert_eq(
    encoded,
    @utf8.encode(
      "HTTP/1.1 200 OK\r\n" +
      "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n" +
      "Content-Length: 21\r\n" +
      "Connection: close\r\n" +
      "Cache-Control: no-store\r\n\r\n" +
      "# HELP x counter\nx 1\n",
    ),
  )
  assert_true(
    encode_response(Ok, PrometheusBody, body, body.length() - 1)
    is Err(ResponseTooLarge),
  )
  assert_true(
    encode_response(Ok, PrometheusBody, body, -1) is Err(ResponseTooLarge),
  )
}
