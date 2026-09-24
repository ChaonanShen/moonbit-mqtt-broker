///|
async fn tls_test_digest(path : String) -> String {
  let (status, output, _) = @process.collect_output("sha256sum", [path])
  assert_eq(status, 0)
  output.text().split(" ").to_array()[0].to_owned()
}

///|
async test "captured TLS bytes publish a leased generation without source reread" {
  let fixture = @fs.tmpdir(prefix="mqtt-reload-tls-")
  let cert = fixture + "/server.crt"
  let key = fixture + "/server.key"
  let config_path = fixture + "/broker.toml"
  let manifest_path = fixture + "/manifest.toml"
  let (status, _, _) = @process.collect_output("openssl", [
    "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "1", "-subj",
    "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-keyout",
    key, "-out", cert,
  ])
  assert_eq(status, 0)
  @fs.chmod(key, 0o600)
  let config_text = "[[listeners]]\nid = \"edge\"\ntransport = \"tls\"\n" +
    "listen = \"127.0.0.1:8883\"\ntls_cert = \"" +
    cert +
    "\"\ntls_key = \"" +
    key +
    "\"\n"
  @fs.write_file(
    config_path,
    @utf8.encode(config_text),
    create_mode=CreateNew,
    permission=0o600,
  )
  let manifest_text = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"" +
    tls_test_digest(config_path) +
    "\"\n[[materials]]\nrole = \"mqtt_cert\"\nlistener_id = \"edge\"\npath = \"" +
    cert +
    "\"\nsha256 = \"" +
    tls_test_digest(cert) +
    "\"\n[[materials]]\nrole = \"mqtt_key\"\nlistener_id = \"edge\"\npath = \"" +
    key +
    "\"\nsha256 = \"" +
    tls_test_digest(key) +
    "\"\n"
  @fs.write_file(
    manifest_path,
    @utf8.encode(manifest_text),
    create_mode=CreateNew,
    permission=0o600,
  )
  let bundle = @bundle.capture_bundle(manifest_path)
  let effective = bundle.evaluate(config_path, [])
  let limits = @budget.Limits::default()
  let ledger = @budget.Ledger::new(
    limits.get("max_managed_bytes_total"),
    limits.get("control_reserve_bytes"),
  ).unwrap()
  let pool = ledger
    .pool(Infrastructure, limits.get("max_managed_bytes_total"))
    .unwrap()
  let baseline = ledger.occupied()
  let runtime_root = fixture + "/tls-runtime"
  @fs.mkdir(runtime_root, permission=0o700)
  let prepared = prepare_tls_generation(bundle, effective, pool, runtime_root)
  let provider = TlsMaterialProvider::new()
  provider.add_initial(
    "edge",
    TlsMaterialLease::capture(TlsServerConfig::new(cert, key).unwrap()),
  )
  let old = provider.acquire("edge").unwrap()
  assert_true(prepared.publish(provider))
  let current = provider.acquire("edge").unwrap()
  assert_true(old.directory != current.directory)
  @fs.remove(cert)
  @fs.remove(key)
  validate_tls_config(current.config)
  old.release()
  current.release()
  provider.close()
  assert_eq(ledger.occupied(), baseline)
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.rmdir(runtime_root)
  @fs.rmdir(fixture)
}
