///|
test "TLS server configuration validates required values" {
  assert_true(TlsServerConfig::new("cert.pem", "key.pem") is Ok(_))
  assert_true(TlsServerConfig::new("", "key.pem") is Err(_))
  assert_true(TlsServerConfig::new("cert.pem", "") is Err(_))
  assert_true(
    TlsServerConfig::new("cert.pem", "key.pem", handshake_timeout_ms=0)
    is Err(_),
  )
  let config = TlsServerConfig::new(
    "server.crt",
    "server.key",
    handshake_timeout_ms=321,
  ).unwrap()
  assert_eq(config.certificate_file(), "server.crt")
  assert_eq(config.private_key_file(), "server.key")
  assert_eq(config.handshake_timeout_ms(), 321)
}
