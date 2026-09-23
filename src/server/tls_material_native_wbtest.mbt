///|
async test "TLS material snapshot survives original replacement and is private" {
  let source = @fs.tmpdir(prefix="mqtt-tls-snapshot-test-")
  let cert = source + "/cert.pem"
  let key = source + "/key.pem"
  @fs.write_file(
    cert,
    b"certificate-v1",
    create_mode=CreateNew,
    permission=0o600,
  )
  @fs.write_file(
    key,
    b"private-key-v1",
    create_mode=CreateNew,
    permission=0o600,
  )
  let lease = TlsMaterialLease::capture(
    TlsServerConfig::new(cert, key).unwrap(),
  )
  assert_eq(
    @fs.read_file(lease.config.certificate_file()).text(),
    "certificate-v1",
  )
  assert_eq(
    @fs.read_file(lease.config.private_key_file()).text(),
    "private-key-v1",
  )
  @fs.remove(cert)
  @fs.remove(key)
  assert_eq(
    @fs.read_file(lease.config.private_key_file()).text(),
    "private-key-v1",
  )
  let directory = lease.directory
  lease.release()
  assert_false(@fs.exists(directory))
  @fs.rmdir(source)
}
