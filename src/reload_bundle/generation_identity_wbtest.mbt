///|
test "generation equality ignores config formatting but includes all hot material bytes" {
  let config = "[security]\npassword_file = \"/srv/passwords\"\n"
  let changed_comment = config + "# rotated by deployment\n"
  let hot = @config.effective_hot_config(config, [])
  let original : ReloadEffectiveCandidate = {
    hot,
    restart: @config.effective_restart_scalars(config, []),
  }
  let reformatted : ReloadEffectiveCandidate = {
    hot: @config.effective_hot_config(changed_comment, []),
    restart: @config.effective_restart_scalars(changed_comment, []),
  }
  let digest_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let digest_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let digest_c = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  let manifest_text = fn(config_digest : String, password_digest : String) {
    "version = 1\n[[materials]]\nrole = \"config\"\npath = \"/srv/config.toml\"\nsha256 = \"" +
    config_digest +
    "\"\n[[materials]]\nrole = \"passwords\"\npath = \"/srv/passwords\"\nsha256 = \"" +
    password_digest +
    "\"\n"
  }
  let initial : CapturedBundle = {
    manifest: @config.parse_reload_manifest(manifest_text(digest_a, digest_b)),
    sources: [],
  }
  let cosmetic : CapturedBundle = {
    manifest: @config.parse_reload_manifest(manifest_text(digest_c, digest_b)),
    sources: [],
  }
  assert_true(
    cosmetic.same_effective_generation(reformatted, initial, original),
  )
  let secret_change : CapturedBundle = {
    manifest: @config.parse_reload_manifest(manifest_text(digest_c, digest_c)),
    sources: [],
  }
  assert_false(
    secret_change.same_effective_generation(reformatted, initial, original),
  )
  let log_change = config + "[observability]\nlog_level = \"debug\"\n"
  let changed : ReloadEffectiveCandidate = {
    hot: @config.effective_hot_config(log_change, []),
    restart: @config.effective_restart_scalars(log_change, []),
  }
  assert_false(cosmetic.same_effective_generation(changed, initial, original))
}
