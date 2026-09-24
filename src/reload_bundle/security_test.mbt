///|
async fn test_sha256_file(path : String) -> String {
  let (status, output, _) = @process.collect_output("sha256sum", [path])
  assert_eq(status, 0)
  output.text().split(" ").to_array()[0].to_owned()
}

///|
async fn test_stop_maintenance(executor : @security.AuthExecutor) -> Unit {
  for _ in 0..<1000 {
    match executor.stop() {
      ControlDone => break
      ControlRetryLater => @async.sleep(1)
      _ => fail("maintenance stop failed")
    }
  }
  for _ in 0..<1000 {
    if executor.is_stopped() == Some(true) {
      assert_eq(executor.destroy(), @security.AuthControlResult::ControlDone)
      return
    }
    @async.sleep(1)
  }
  fail("maintenance worker did not stop")
}

///|
async test "verified bundle prepares a password and ACL policy" {
  let root = @fs.tmpdir(prefix="mqtt-reload-security-")
  let config_path = root + "/config.toml"
  let passwords_path = root + "/passwords"
  let acl_path = root + "/acl"
  let manifest_path = root + "/manifest.toml"
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  @fs.write_file(
    passwords_path,
    @utf8.encode("sensor01:" + encoded + "\n"),
    create_mode=CreateNew,
    permission=0o600,
  )
  @fs.write_file(
    acl_path,
    b"user sensor01\ntopic read safe/#\n",
    create_mode=CreateNew,
    permission=0o600,
  )
  let config_text = "[security]\nallow_anonymous = false\npassword_file = \"" +
    passwords_path +
    "\"\nacl_file = \"" +
    acl_path +
    "\"\n"
  @fs.write_file(
    config_path,
    @utf8.encode(config_text),
    create_mode=CreateNew,
    permission=0o600,
  )
  let config_digest = test_sha256_file(config_path)
  let passwords_digest = test_sha256_file(passwords_path)
  let acl_digest = test_sha256_file(acl_path)
  let manifest_text = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"" +
    config_digest +
    "\"\n[[materials]]\nrole = \"passwords\"\npath = \"" +
    passwords_path +
    "\"\nsha256 = \"" +
    passwords_digest +
    "\"\n[[materials]]\nrole = \"acl\"\npath = \"" +
    acl_path +
    "\"\nsha256 = \"" +
    acl_digest +
    "\"\n"
  @fs.write_file(
    manifest_path,
    @utf8.encode(manifest_text),
    create_mode=CreateNew,
    permission=0o600,
  )
  let bundle = capture_bundle(manifest_path)
  let candidate = bundle.evaluate(config_path, [])
  let maintenance = @security.AuthExecutor::new(1, 0).unwrap()
  let policy = bundle.prepare_security(candidate, maintenance)
  assert_true(policy.has_passwords())
  assert_true(policy.allows_principal(@security.Principal::User("sensor01")))
  assert_false(policy.allows_principal(@security.Principal::Anonymous))
  test_stop_maintenance(maintenance)
  let isolated = bundle.prepare_security_isolated(candidate)
  assert_true(isolated.has_passwords())
  assert_false(isolated.allows_principal(@security.Principal::Anonymous))
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.remove(passwords_path)
  @fs.remove(acl_path)
  @fs.rmdir(root)
}
