///|
/// Parses only captured bytes. Expensive PHC verification runs on the caller's
/// reserved maintenance executor, never on the online authentication pool.
pub async fn CapturedBundle::prepare_security(
  self : CapturedBundle,
  candidate : ReloadEffectiveCandidate,
  maintenance : @security.AuthExecutor,
) -> @security.SecurityPolicy {
  let hot = candidate.hot()
  let passwords : @security.PasswordDatabase? = match hot.password_file {
    None => None
    Some(_) => {
      let bytes = match self.material_bytes("passwords") {
        Some(value) => value
        None => raise BundleError("bundle lacks password material")
      }
      let contents = @utf8.decode(bytes) catch {
        _ => raise BundleError("password material must be UTF-8")
      }
      let parsed = match @security.PasswordDatabaseCandidate::parse(contents) {
        Ok(value) => value
        Err(_) => raise BundleError("invalid password material")
      }
      Some(
        parsed.validate_with(maintenance) catch {
          _ => raise BundleError("password validation failed")
        },
      )
    }
  }
  let acl : @security.AclPolicy? = match hot.acl_file {
    None => None
    Some(_) => {
      let bytes = match self.material_bytes("acl") {
        Some(value) => value
        None => raise BundleError("bundle lacks ACL material")
      }
      let contents = @utf8.decode(bytes) catch {
        _ => raise BundleError("ACL material must be UTF-8")
      }
      let parsed = match @security.AclPolicy::parse(contents) {
        Ok(value) => value
        Err(_) => raise BundleError("invalid ACL material")
      }
      if parsed.rule_count() > 4096 {
        raise BundleError("ACL rule count exceeds limit")
      }
      Some(parsed)
    }
  }
  @security.SecurityPolicy::new(
    allow_anonymous=hot.allow_anonymous,
    passwords?,
    acl?,
  )
}
