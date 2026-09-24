///|
pub enum ReloadPrepareResult {
  ReloadNoChange
  ReloadPrepared(PreparedReload)
}

///|
pub struct PreparedReload {
  bundle : @bundle.CapturedBundle
  effective : @bundle.ReloadEffectiveCandidate
  security : @security.SecurityPolicy
  fingerprint : Bytes
  tls : PreparedTlsGeneration?
  budget : @budget.Ticket
  mut released : Bool
  security_changed : Bool
}

///|
pub fn PreparedReload::release(self : PreparedReload) -> Unit {
  if self.released {
    return
  }
  self.released = true
  if self.tls is Some(value) {
    value.release()
  }
  self.budget.release().unwrap()
}

///|
pub fn PreparedReload::security_changed(self : PreparedReload) -> Bool {
  self.security_changed
}

///|
pub fn PreparedReload::fingerprint(self : PreparedReload) -> Bytes {
  self.fingerprint
}

///|
pub fn PreparedReload::security(
  self : PreparedReload,
) -> @security.SecurityPolicy {
  self.security
}

///|
pub fn PreparedReload::effective(
  self : PreparedReload,
) -> @bundle.ReloadEffectiveCandidate {
  self.effective
}

///|
fn same_tls_materials(
  next : @bundle.CapturedBundle,
  previous : @bundle.CapturedBundle,
) -> Bool {
  let next_materials = next.manifest().materials
  let old_materials = previous.manifest().materials
  for material in next_materials {
    if material.role != "mqtt_cert" && material.role != "mqtt_key" {
      continue
    }
    if !old_materials.any(before => before == material) {
      return false
    }
  }
  for material in old_materials {
    if (material.role == "mqtt_cert" || material.role == "mqtt_key") &&
      !next_materials.any(after => after == material) {
      return false
    }
  }
  true
}

///|
/// A candidate owns its captured bytes, policy, optional TLS lease generation,
/// and ledger reservation until the caller publishes it or releases it. The
/// entire worker/cancellation/reap path is inside the deadline.
pub async fn prepare_reload_candidate(
  manifest_path : String,
  config_path : String,
  cli_args : Array[String],
  previous_bundle : @bundle.CapturedBundle,
  previous_effective : @bundle.ReloadEffectiveCandidate,
  previous_security : @security.SecurityPolicy,
  pool : @budget.Pool,
  runtime_root : String,
  timeout_ms : Int,
  max_source_bytes : Int,
  max_generation_bytes : Int64,
  max_accounts? : Int = 4096,
  max_acl_rules? : Int = 4096,
) -> ReloadPrepareResult {
  if timeout_ms < 1 ||
    timeout_ms > 300000 ||
    max_generation_bytes < 4096L ||
    max_generation_bytes > 268435456L {
    raise ResourceStartupFailure("invalid reload prepare limits")
  }
  let capacity_bytes = (max_generation_bytes - 4096L) / 3L
  let capture_limit = if max_source_bytes.to_int64() < capacity_bytes {
    max_source_bytes
  } else {
    capacity_bytes.to_int()
  }
  if capture_limit < 16384 {
    raise ResourceStartupFailure("reload source budget unavailable")
  }
  let reservation = capture_limit.to_int64() * 3L + 4096L
  let ticket = match pool.reserve(reservation) {
    Ok(value) => value
    Err(_) =>
      raise ResourceStartupFailure("reload generation budget unavailable")
  }
  ticket.commit().unwrap()
  let mut transferred = false
  errdefer (if !transferred { ticket.release().unwrap() })
  @async.with_timeout(timeout_ms, () => {
    let bundle = @bundle.capture_bundle(
      manifest_path,
      max_source_bytes=capture_limit,
    ) catch {
      @bundle.BundleError(message) =>
        if message == "source_changed" {
          @bundle.capture_bundle(manifest_path, max_source_bytes=capture_limit)
        } else {
          raise @bundle.BundleError(message)
        }
      error => raise error
    }
    let effective = bundle.evaluate(config_path, cli_args)
    let hot = effective.hot()
    if hot.management_snapshot_interval_ms < 100 ||
      hot.management_snapshot_interval_ms > 10000 ||
      hot.management_snapshot_max_age_ms < 300 ||
      hot.management_snapshot_max_age_ms > 60000 ||
      hot.management_snapshot_max_age_ms <
      3 * hot.management_snapshot_interval_ms {
      raise ResourceStartupFailure("invalid reload management snapshot timing")
    }
    if !effective.restart_compatible(previous_effective) {
      raise ResourceStartupFailure("reload requires restart")
    }
    if bundle.same_effective_generation(
        effective, previous_bundle, previous_effective,
      ) {
      ticket.release().unwrap()
      transferred = true
      return ReloadNoChange
    }
    let source_bytes = bundle
      .sources()
      .fold(init=0L, (total, source) => total + source.bytes.length().to_int64())
    let cost = source_bytes * 3L + 4096L
    if cost > max_generation_bytes {
      raise ResourceStartupFailure("reload generation exceeds byte limit")
    }
    let fingerprint = bundle.policy_fingerprint(effective)
    let previous_fingerprint = previous_bundle.policy_fingerprint(
      previous_effective,
    )
    let security_changed = fingerprint != previous_fingerprint
    let security = if security_changed {
      bundle.prepare_security_isolated(effective, max_accounts~, max_acl_rules~)
    } else {
      previous_security
    }
    let tls = if same_tls_materials(bundle, previous_bundle) {
      None
    } else {
      Some(prepare_tls_generation(bundle, effective, pool, runtime_root))
    }
    transferred = true
    ReloadPrepared({
      bundle,
      effective,
      security,
      fingerprint,
      tls,
      budget: ticket,
      released: false,
      security_changed,
    })
  })
}
