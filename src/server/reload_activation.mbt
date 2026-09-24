///|
pub(all) enum ReloadActivationResult {
  ReloadActivated(Int64, Int64)
  ReloadActivationStale
  ReloadActivationBusy
  ReloadActivationInvalid
} derive(Eq, Debug)

///|
fn reload_log_level(value : String) -> @observability.LogLevel {
  match value {
    "error" => @observability.Error
    "warn" => @observability.Warn
    "info" => @observability.Info
    "debug" => @observability.Debug
    _ => abort("validated reload log level invalid")
  }
}

///|
fn reload_log_format(value : String) -> @observability.LogFormat {
  match value {
    "text" => @observability.Text
    "json" => @observability.Json
    _ => abort("validated reload log format invalid")
  }
}

///|
fn RouterDriver::retire_released_generations(self : RouterDriver) -> Unit {
  if self.retired_generations.is_empty() {
    return
  }
  let remaining : Array[ConfigGeneration] = []
  for old in self.retired_generations {
    if self.runtime.policy_reference_count(old.policy_epoch()) == 0 {
      old.release()
    } else {
      remaining.push(old)
    }
  }
  self.retired_generations = remaining
}

///|
/// Called at the driver boundary after candidate preparation. Strict callers
/// first commit PolicyActivated (if security changed) and enter the barrier.
/// All checks precede the non-awaiting publication sequence.
pub fn RouterDriver::activate_prepared_reload(
  self : RouterDriver,
  prepared : PreparedReload,
  expected_epoch : Int64,
) -> ReloadActivationResult {
  self.retire_released_generations()
  let handle = match self.generation {
    Some(value) => value
    None => return ReloadActivationInvalid
  }
  let active = handle.active()
  if active.config_epoch() != expected_epoch {
    return ReloadActivationStale
  }
  if self.runtime.broker_state().policy_action_scope_active() {
    return ReloadActivationBusy
  }
  if self.strict is Some(coordinator) {
    if !self.reload_barrier_ready() {
      return ReloadActivationBusy
    }
    if prepared.security_changed {
      let expected_sequence = active.policy_epoch() + 1L
      match coordinator.policy_state() {
        Some(value) if value.sequence == expected_sequence &&
          value.fingerprint == prepared.fingerprint &&
          value.reconcile_pending => ()
        _ => return ReloadActivationInvalid
      }
    }
  }
  if prepared.security_changed &&
    !self.runtime.can_publish_security_generation(
      prepared.security,
      active.policy_epoch() + 1L,
    ) {
    return ReloadActivationBusy
  }
  if prepared.tls is Some(tls) {
    let provider = match self.material_provider {
      Some(value) => value
      None => return ReloadActivationInvalid
    }
    if !provider.can_publish_generation(tls.leases) {
      return ReloadActivationBusy
    }
  }
  // No await or callback to user code occurs until the complete root is live.
  if prepared.tls is Some(tls) {
    if !tls.publish(self.material_provider.unwrap()) {
      abort("validated TLS generation failed to publish")
    }
  }
  if prepared.security_changed &&
    !self.runtime.publish_security_generation(
      prepared.security,
      active.policy_epoch() + 1L,
    ) {
    abort("validated security generation failed to publish")
  }
  let hot = prepared.effective.hot()
  self.runtime.logger.reconfigure(
    reload_log_level(hot.log_level),
    reload_log_format(hot.log_format),
  )
  let retired = match handle.publish(prepared, expected_epoch) {
    Some(value) => value
    None => abort("validated config generation failed to publish")
  }
  if prepared.security_changed &&
    self.runtime.policy_reference_count(retired.policy_epoch()) > 0 {
    self.retired_generations.push(retired)
  } else {
    retired.release()
  }
  let now = handle.active()
  ReloadActivated(now.config_epoch(), now.policy_epoch())
}
