///|
async test "bundle capture verifies all declared digests and source bytes" {
  let root = @fs.tmpdir(prefix="mqtt-reload-bundle-")
  let config_path = root + "/config.toml"
  let manifest_path = root + "/manifest.toml"
  @fs.write_file(config_path, b"abc", create_mode=CreateNew, permission=0o600)
  let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  let manifest_text = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"" +
    digest +
    "\"\n"
  @fs.write_file(
    manifest_path,
    @utf8.encode(manifest_text),
    create_mode=CreateNew,
    permission=0o600,
  )
  let bundle = capture_bundle(manifest_path)
  assert_eq(bundle.sources().length(), 1)
  assert_eq(bundle.sources()[0].bytes, b"abc")
  bundle.manifest().validate_effective_paths(config_path, None, None, [])
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.rmdir(root)
}

///|
async test "bundle capture rejects mismatched digest without accepting source" {
  let root = @fs.tmpdir(prefix="mqtt-reload-digest-")
  let config_path = root + "/config.toml"
  let manifest_path = root + "/manifest.toml"
  @fs.write_file(config_path, b"abc", create_mode=CreateNew, permission=0o600)
  let manifest_text = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"0000000000000000000000000000000000000000000000000000000000000000\"\n"
  @fs.write_file(
    manifest_path,
    @utf8.encode(manifest_text),
    create_mode=CreateNew,
    permission=0o600,
  )
  let rejected = try {
    ignore(capture_bundle(manifest_path))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.rmdir(root)
}

///|
async test "bundle evaluation binds effective paths to captured config" {
  let root = @fs.tmpdir(prefix="mqtt-reload-effective-")
  let config_path = root + "/config.toml"
  let manifest_path = root + "/manifest.toml"
  let contents = "[security]\nallow_anonymous = true\n"
  @fs.write_file(
    config_path,
    @utf8.encode(contents),
    create_mode=CreateNew,
    permission=0o600,
  )
  let manifest_text = "version = 1\n[[materials]]\nrole = \"config\"\npath = \"" +
    config_path +
    "\"\nsha256 = \"ca8c5bf54799d9e1f085f25416f8ad91d2637213a87951e0f0b3f01458bcd5a0\"\n"
  @fs.write_file(
    manifest_path,
    @utf8.encode(manifest_text),
    create_mode=CreateNew,
    permission=0o600,
  )
  let bundle = capture_bundle(manifest_path)
  let candidate = bundle.evaluate(config_path, [])
  assert_true(candidate.hot().allow_anonymous)
  assert_eq(candidate.hot().password_file, None)
  let rejected = try {
    ignore(bundle.evaluate(root + "/other.toml", []))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  @fs.remove(manifest_path)
  @fs.remove(config_path)
  @fs.rmdir(root)
}
