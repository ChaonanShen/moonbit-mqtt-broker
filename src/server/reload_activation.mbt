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
  if self.runtime.broker_state().policy_action_scope_active() ||
    self.reload_reconciler is Some(_) {
    return ReloadActivationBusy
  }
  let scan = if prepared.security_changed {
    match
      @router.PolicyReconciler::new(
        prepared.security,
        active.policy_epoch() + 1L,
        self.reload_reconcile_items,
        self.reload_reconcile_bytes,
      ) {
      Some(value) => Some(value)
      None => return ReloadActivationInvalid
    }
  } else {
    None
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
  self.reload_reconciler = scan
  if self.strict is Some(_) {
    self.end_reload_barrier()
  }
  let now = handle.active()
  ReloadActivated(now.config_epoch(), now.policy_epoch())
}

///|
fn RouterDriver::advance_reload_reconciliation(self : RouterDriver) -> Unit {
  let scan = match self.reload_reconciler {
    Some(value) => value
    None => return
  }
  if self.strict_fenced {
    return
  }
  let issue = match self.reload_issue {
    Some(value) => Some(value)
    None =>
      match scan.next(self.runtime.broker_state()) {
        @router.PolicyScanIssue(value) => {
          self.reload_issue = Some(value)
          Some(value)
        }
        @router.PolicyScanProgress => return
        @router.PolicyScanWaiting => return
        @router.PolicyScanUnavailable =>
          abort("reload policy index became unavailable")
        @router.PolicyScanDone => {
          if self.strict is Some(coordinator) {
            if coordinator.has_pending() ||
              self.strict_checkpoint_cursor is Some(_) ||
              self.strict_checkpoint_inflight {
              return
            }
            let active = self.generation.unwrap().active()
            let state = match coordinator.policy_state() {
              Some(value) if value.reconcile_pending &&
                value.sequence == active.policy_epoch() &&
                value.fingerprint == active.fingerprint => value
              _ => {
                self.strict_fence("reload-policy-state-mismatch")
                return
              }
            }
            match
              coordinator.submit(
                PolicyRecord({
                  transition: @persistence.PolicyReconciled,
                  sequence: state.sequence,
                  fingerprint: state.fingerprint,
                }),
                _ => {
                  self.reload_issue = None
                  self.reload_reconciler = None
                  []
                },
              ) {
              Ok(_) => ()
              Err(CommitBusy) => ()
              Err(_) => self.strict_fence("reload-reconciled-submit")
            }
          } else {
            self.reload_reconciler = None
          }
          return
        }
      }
  }
  let value = issue.unwrap()
  if self.strict is Some(_) {
    match self.apply_policy_issue_strict(value, scan) {
      PolicyIssueSubmitted | PolicyClosePending | PolicyIssueBusy => ()
      PolicyIssueStale => self.reload_issue = None
      PolicyIssueFailed => self.strict_fence("reload-policy-cleanup")
    }
  } else {
    match self.runtime.apply_policy_issue_runtime(value) {
      PolicyApplied(actions) => {
        self.dispatch(actions)
        ignore(scan.complete_issue(value))
        self.reload_issue = None
      }
      PolicyStale => {
        ignore(scan.complete_issue(value))
        self.reload_issue = None
      }
      PolicyFailed => abort("runtime reload policy cleanup failed")
    }
  }
}

///|
fn RouterDriver::handle_reload_control(
  self : RouterDriver,
  command : ReloadDriverCommand,
) -> Unit {
  match command {
    ReloadEnterBarrier(reply) => {
      let ready = if self.strict is None {
        true
      } else if self.reload_barrier_ready() {
        true
      } else {
        ignore(self.begin_reload_barrier())
        self.reload_barrier_ready()
      }
      ignore(
        reply.try_put(
          if ready {
            ReloadDriverReady
          } else {
            ReloadDriverWaiting
          },
        ),
      ) catch {
        _ => ()
      }
    }
    ReloadActivate(candidate, expected_epoch, reply) => {
      let result = self.activate_prepared_reload(candidate, expected_epoch)
      let response = match result {
        ReloadActivated(config_epoch, policy_epoch) =>
          ReloadDriverActivated(config_epoch, policy_epoch)
        ReloadActivationBusy => ReloadDriverWaiting
        ReloadActivationStale => ReloadDriverRejected("stale_generation")
        ReloadActivationInvalid => ReloadDriverRejected("invalid_candidate")
      }
      if !(reply.try_put(response) catch { _ => false }) {
        candidate.release()
      }
    }
    ReloadCommitPolicy(candidate, expected_epoch, reply) =>
      self.stage_strict_reload(candidate, expected_epoch, reply)
    ReloadQueryCompletion(expected_epoch, reply) => {
      let state = match self.generation {
        Some(handle) if handle.active().config_epoch() == expected_epoch =>
          if self.strict_fenced {
            ReloadDriverRejected("durability_fenced")
          } else if self.reload_reconciler is Some(_) ||
            self.strict_reload_pending is Some(_) ||
            (
              self.strict is Some(coordinator) &&
              coordinator.policy_state()
              is Some({ reconcile_pending: true, .. })
            ) {
            ReloadDriverWaiting
          } else {
            ReloadDriverReady
          }
        _ => ReloadDriverRejected("stale_generation")
      }
      ignore(reply.try_put(state)) catch {
        _ => ()
      }
    }
  }
}

///|
fn RouterDriver::stage_strict_reload(
  self : RouterDriver,
  candidate : PreparedReload,
  expected_epoch : Int64,
  reply : @async.Queue[ReloadDriverReply],
) -> Unit {
  let coordinator = match self.strict {
    Some(value) => value
    None => {
      ignore(reply.try_put(ReloadDriverRejected("not_strict"))) catch {
        _ => ()
      }
      return
    }
  }
  let active = match self.generation {
    Some(value) => value.active()
    None => {
      ignore(reply.try_put(ReloadDriverRejected("reload_disabled"))) catch {
        _ => ()
      }
      return
    }
  }
  if !candidate.security_changed ||
    active.config_epoch() != expected_epoch ||
    self.strict_reload_pending is Some(_) ||
    self.reload_reconciler is Some(_) {
    ignore(reply.try_put(ReloadDriverRejected("stale_generation"))) catch {
      _ => ()
    }
    return
  }
  if !self.reload_barrier_ready() {
    ignore(reply.try_put(ReloadDriverWaiting)) catch {
      _ => ()
    }
    return
  }
  match coordinator.policy_state() {
    Some(state) if !state.reconcile_pending &&
      state.sequence == active.policy_epoch() &&
      state.fingerprint == active.fingerprint => ()
    _ => {
      ignore(reply.try_put(ReloadDriverRejected("policy_state_mismatch"))) catch {
        _ => ()
      }
      return
    }
  }
  if !self.runtime.can_publish_security_generation(
      candidate.security,
      active.policy_epoch() + 1L,
    ) {
    ignore(reply.try_put(ReloadDriverWaiting)) catch {
      _ => ()
    }
    return
  }
  let pending : StrictReloadPending = {
    candidate,
    expected_epoch,
    reply,
    committed: false,
  }
  match
    coordinator.submit(
      PolicyRecord({
        transition: @persistence.PolicyActivated,
        sequence: active.policy_epoch() + 1L,
        fingerprint: candidate.fingerprint,
      }),
      _ => {
        pending.committed = true
        []
      },
    ) {
    Ok(_) => {
      self.strict_reload_pending = Some(pending)
      ignore(reply.try_put(ReloadDriverStaged)) catch {
        _ => ()
      }
    }
    Err(CommitBusy) =>
      ignore(reply.try_put(ReloadDriverWaiting)) catch {
        _ => ()
      }
    Err(_) => {
      self.strict_fence("reload-policy-activated-submit")
      ignore(reply.try_put(ReloadDriverRejected("durability_failed"))) catch {
        _ => ()
      }
    }
  }
}

///|
fn RouterDriver::finish_committed_reload(self : RouterDriver) -> Unit {
  let pending = match self.strict_reload_pending {
    Some(value) if value.committed => value
    _ => return
  }
  self.strict_reload_pending = None
  let outcome = self.activate_prepared_reload(
    pending.candidate,
    pending.expected_epoch,
  )
  let response = match outcome {
    ReloadActivated(config_epoch, policy_epoch) =>
      ReloadDriverActivated(config_epoch, policy_epoch)
    _ => {
      pending.candidate.release()
      self.strict_fence("reload-committed-publication")
      ReloadDriverRejected("durability_failed")
    }
  }
  ignore(pending.reply.try_put(response)) catch {
    _ => ()
  }
}
