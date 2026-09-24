///|
pub struct ReloadEffectiveCandidate {
  hot : @config.HotConfig
  restart : @config.RestartScalars
}

///|
pub fn ReloadEffectiveCandidate::hot(
  self : ReloadEffectiveCandidate,
) -> @config.HotConfig {
  self.hot
}

///|
pub fn ReloadEffectiveCandidate::restart_compatible(
  self : ReloadEffectiveCandidate,
  previous : ReloadEffectiveCandidate,
) -> Bool {
  self.restart.same_values(previous.restart) &&
  self.hot.same_listener_topology(previous.hot)
}

///|
/// Returns only bytes captured from the manifest-selected source. The caller
/// keeps this material out of logs, labels, and HTTP responses.
pub fn CapturedBundle::material_bytes(
  self : CapturedBundle,
  role : String,
  listener_id? : String = "",
) -> Bytes? {
  for source in self.sources {
    if source.material.role == role &&
      source.material.listener_id.unwrap_or("") == listener_id {
      return Some(source.bytes)
    }
  }
  None
}

///|
pub fn CapturedBundle::evaluate(
  self : CapturedBundle,
  config_path : String,
  frozen_cli_args : Array[String],
) -> ReloadEffectiveCandidate raise BundleError {
  let config_bytes = match self.material_bytes("config") {
    Some(value) => value
    None => raise BundleError("bundle lacks config source")
  }
  let contents = @utf8.decode(config_bytes) catch {
    _ => raise BundleError("config source must be UTF-8")
  }
  let hot = @config.effective_hot_config(contents, frozen_cli_args) catch {
    _ => raise BundleError("invalid effective hot config")
  }
  let restart = @config.effective_restart_scalars(contents, frozen_cli_args) catch {
    _ => raise BundleError("invalid restart-only config")
  }
  let tls : Array[@config.ReloadTlsPaths] = []
  for source in hot.tls_sources {
    tls.push({
      listener_id: source.listener_id,
      cert_path: source.cert_path,
      key_path: source.key_path,
    })
  }
  self.manifest.validate_effective_paths(
    config_path,
    hot.password_file,
    hot.acl_file,
    tls,
  ) catch {
    _ => raise BundleError("manifest differs from effective source paths")
  }
  { hot, restart }
}
