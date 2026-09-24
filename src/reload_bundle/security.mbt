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

///|
async fn stop_security_maintenance(worker : @security.AuthExecutor) -> Unit {
  @async.protect_from_cancel(() => {
    for ;; {
      if worker.stop() == @security.ControlDone {
        break
      }
      @async.sleep(1)
    }
    for ;; {
      if worker.is_stopped() == Some(true) {
        break
      }
      @async.sleep(1)
    }
    for ;; {
      if worker.destroy() == @security.ControlDone {
        break
      }
      @async.sleep(1)
    }
  })
}

///|
/// Owns a separate one-worker maintenance executor for initial policy
/// validation. Stop, drain, and destroy complete before startup continues.
pub async fn CapturedBundle::prepare_security_isolated(
  self : CapturedBundle,
  candidate : ReloadEffectiveCandidate,
) -> @security.SecurityPolicy {
  let worker = match @security.AuthExecutor::new(1, 1) {
    Ok(value) => value
    Err(_) => raise BundleError("security maintenance backend unavailable")
  }
  errdefer stop_security_maintenance(worker)
  let policy = self.prepare_security(candidate, worker)
  stop_security_maintenance(worker)
  policy
}
