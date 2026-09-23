///|
fn parsed_ws_head(value : String) -> @http_transport.HttpRequestHead {
  let parser = @http_transport.HttpParser::new(16384, 64)
  match parser.feed(@utf8.encode(value)) {
    Complete(head, _) => head
    _ => abort("invalid test HTTP request")
  }
}

///|
test "websocket upgrade selects mqtt and rejects ambiguous transport headers" {
  assert_true(websocket_crypto_ready())
  let policy = WebSocketPolicy::new().unwrap()
  let prefix = "GET /mqtt HTTP/1.1\r\nHost: localhost\r\n"
  let normal = prefix +
    "Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n" +
    "Sec-WebSocket-Version: 13\r\n" +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
    "Sec-WebSocket-Protocol: other, mqtt\r\n\r\n"
  assert_eq(
    websocket_validate_upgrade(parsed_ws_head(normal), policy),
    Some("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="),
  )
  assert_true(
    websocket_validate_upgrade(
      parsed_ws_head(
        normal.replace_all(
          old="Upgrade: websocket",
          new="Upgrade: notwebsocket",
        ),
      ),
      policy,
    )
    is None,
  )
  assert_true(
    websocket_validate_upgrade(
      parsed_ws_head(normal.replace_all(old="other, mqtt", new="other, MQTT")),
      policy,
    )
    is None,
  )
  assert_true(
    websocket_validate_upgrade(
      parsed_ws_head(
        normal.replace_all(
          old="\r\n\r\n",
          new="\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
        ),
      ),
      policy,
    )
    is None,
  )
}

///|
test "websocket origin is denied unless explicitly allowed" {
  assert_true(websocket_crypto_ready())
  let request = parsed_ws_head(
    "GET /mqtt HTTP/1.1\r\nHost: localhost\r\n" +
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
    "Sec-WebSocket-Version: 13\r\n" +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
    "Sec-WebSocket-Protocol: mqtt\r\n" +
    "Origin: https://dashboard.example.com\r\n\r\n",
  )
  assert_true(
    websocket_validate_upgrade(request, WebSocketPolicy::new().unwrap()) is None,
  )
  assert_true(
    websocket_validate_upgrade(
      request,
      WebSocketPolicy::new(allowed_origins=["https://dashboard.example.com"]).unwrap(),
    )
    is Some(_),
  )
}
