///|
async test "TLS provider retains a lease through a connection after close" {
  let source = @fs.tmpdir(prefix="mqtt-tls-provider-test-")
  let cert = source + "/cert.pem"
  let key = source + "/key.pem"
  @fs.write_file(cert, b"certificate", create_mode=CreateNew, permission=0o600)
  @fs.write_file(key, b"private-key", create_mode=CreateNew, permission=0o600)
  let lease = TlsMaterialLease::capture(
    TlsServerConfig::new(cert, key).unwrap(),
  )
  let provider = TlsMaterialProvider::new()
  provider.add_initial("edge", lease)
  let borrowed = provider.acquire("edge").unwrap()
  provider.close()
  assert_true(@fs.exists(lease.directory))
  assert_eq(
    @fs.read_file(borrowed.config.private_key_file()).text(),
    "private-key",
  )
  borrowed.release()
  assert_false(@fs.exists(lease.directory))
  assert_true(provider.acquire("edge") is None)
  @fs.remove(cert)
  @fs.remove(key)
  @fs.rmdir(source)
}
