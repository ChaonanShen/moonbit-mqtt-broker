///|
test "websocket accept uses canonical RFC 6455 SHA-1 vector" {
  assert_true(websocket_crypto_ready())
  assert_eq(
    websocket_accept("dGhlIHNhbXBsZSBub25jZQ=="),
    Some("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="),
  )
  assert_eq(websocket_accept("dGhlIHNhbXBsZSBub25jZQ=A"), None)
  assert_eq(websocket_accept("dGhlIHNhbXBsZSBub25jZQ== "), None)
}
