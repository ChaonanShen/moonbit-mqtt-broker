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

///|
async test "TLS provider publishes new material without retiring borrowed old lease" {
  let source = @fs.tmpdir(prefix="mqtt-tls-swap-test-")
  let cert = source + "/cert.pem"
  let key = source + "/key.pem"
  @fs.write_file(
    cert,
    b"certificate-v1",
    create_mode=CreateNew,
    permission=0o600,
  )
  @fs.write_file(key, b"key-v1", create_mode=CreateNew, permission=0o600)
  let config = TlsServerConfig::new(cert, key).unwrap()
  let old = TlsMaterialLease::capture(config)
  let provider = TlsMaterialProvider::new()
  provider.add_initial("edge", old)
  let borrowed = provider.acquire("edge").unwrap()
  @fs.remove(cert)
  @fs.remove(key)
  @fs.write_file(
    cert,
    b"certificate-v2",
    create_mode=CreateNew,
    permission=0o600,
  )
  @fs.write_file(key, b"key-v2", create_mode=CreateNew, permission=0o600)
  let next = TlsMaterialLease::capture(config)
  assert_true(provider.publish_prepared("edge", next))
  assert_true(@fs.exists(old.directory))
  assert_eq(@fs.read_file(borrowed.config.private_key_file()).text(), "key-v1")
  let new_borrow = provider.acquire("edge").unwrap()
  assert_eq(
    @fs.read_file(new_borrow.config.private_key_file()).text(),
    "key-v2",
  )
  borrowed.release()
  assert_false(@fs.exists(old.directory))
  new_borrow.release()
  provider.close()
  assert_false(@fs.exists(next.directory))
  @fs.remove(cert)
  @fs.remove(key)
  @fs.rmdir(source)
}
