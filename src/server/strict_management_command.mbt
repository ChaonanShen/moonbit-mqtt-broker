///|
fn RouterDriver::strict_delete_failed(
  self : RouterDriver,
  operation_id : String,
  code : String,
  timed_out? : Bool = false,
) -> Unit {
  let active = match self.management {
    Some(value) => value
    None => return
  }
  let table = match active.operations {
    Some(value) => value
    None => return
  }
  ignore(
    table.finish(
      operation_id,
      false,
      false,
      false,
      timed_out,
      Some(code),
      None,
      None,
      @async.now(),
      @budget.monotonic_ms(),
    ),
  )
}

///|
fn RouterDriver::run_strict_management_delete(
  self : RouterDriver,
  operation_id : String,
  spec : @management.CommandSpec,
) -> Unit {
  let active = match self.management {
    Some(value) => value
    None => return
  }
  let table = match active.operations {
    Some(value) => value
    None => return
  }
  let record = match table.get_internal(operation_id) {
    Some(value) if value.state == @management.Accepted => value
    _ => return
  }
  let now_mono = @budget.monotonic_ms()
  if now_mono >= record.deadline_monotonic_ms {
    self.strict_delete_failed(operation_id, "timeout", timed_out=true)
    return
  }
  let started_at = @async.now()
  ignore(table.start(operation_id, @management.Applying, started_at))
  if active.audit is Some(ring) {
    ignore(
      ring.append({
        sequence: 0L,
        timestamp_ms: started_at,
        actor_token_id: spec.actor_token_id,
        operation_id,
        kind: @management.DeleteSession,
        target: spec.target,
        phase: "started",
        result: "running",
        effect_applied: false,
        state_revision: None,
      }),
    )
  }
  let etag = match @management.parse_strong_etag(spec.if_match, "s") {
    Ok(value) => value
    Err(_) => {
      self.strict_delete_failed(operation_id, "bad_request")
      return
    }
  }
  let view = match self.runtime.broker_state().admin_session_view(etag.target) {
    Some(value) => value
    None => {
      self.strict_delete_failed(operation_id, "not_found")
      return
    }
  }
  let client_id = match @session.ClientId::new(view.client_id) {
    Ok(value) => value
    Err(_) => {
      self.strict_delete_failed(operation_id, "invariant_violation")
      self.strict_fence("admin-client-id")
      return
    }
  }
  let generation = match self.strict_generations.get(client_id) {
    Some(value) => value
    None => {
      self.strict_delete_failed(operation_id, "invariant_violation")
      self.strict_fence("admin-generation")
      return
    }
  }
  let plan = match
    self.runtime
    .broker_state()
    .prepare_durable_admin_delete(
      etag.target,
      etag.lifecycle_version.unwrap(),
      generation,
    ) {
    Ok(value) => value
    Err(@router.AdminNotFound) => {
      self.strict_delete_failed(operation_id, "not_found")
      return
    }
    Err(@router.AdminPreconditionFailed) => {
      self.strict_delete_failed(operation_id, "precondition_failed")
      return
    }
    Err(@router.AdminSessionActive) => {
      self.strict_delete_failed(operation_id, "session_active")
      return
    }
    Err(@router.AdminDetailsUnavailable) => {
      self.strict_delete_failed(operation_id, "details_unavailable")
      return
    }
    Err(_) => {
      self.strict_delete_failed(operation_id, "invariant_violation")
      return
    }
  }
  let coordinator = self.strict.unwrap()
  let submitted = coordinator.submit(Lifecycle(plan), broker_actions => {
    let revision = Some(self.runtime.broker_state().snapshot_revision())
    let lsn = coordinator.committed_lsn()
    let finished_at = @async.now()
    ignore(
      table.finish(
        operation_id,
        true,
        true,
        false,
        false,
        None,
        revision,
        None,
        finished_at,
        @budget.monotonic_ms(),
      ),
    )
    ignore(table.mark_durable_finish(operation_id, lsn))
    if active.audit is Some(ring) {
      ignore(
        ring.append({
          sequence: 0L,
          timestamp_ms: finished_at,
          actor_token_id: record.actor_token_id,
          operation_id,
          kind: @management.DeleteSession,
          target: record.target,
          phase: "completed",
          result: "succeeded",
          effect_applied: true,
          state_revision: revision,
        }),
      )
    }
    self.runtime.admission.prune_publishers(self.runtime.broker_state())
    self.runtime.map_broker_actions(broker_actions)
  })
  match submitted {
    Ok(_) => ()
    Err(CommitEncoding) | Err(CommitBudget) =>
      self.strict_delete_failed(operation_id, "capacity_exhausted")
    Err(_) => {
      self.strict_delete_failed(operation_id, "durability_unavailable")
      self.strict_fence("admin-delete-submit")
    }
  }
}

///|
fn RouterDriver::handle_strict_management_command(
  self : RouterDriver,
  event : ManagementCommandEvent,
) -> Unit {
  if self.strict_fenced {
    match event {
      SubmitCommand(ticket, _, _) =>
        if self.management is Some(active) &&
          active.command_mailbox is Some(mailbox) {
          mailbox.produce(
            ticket,
            management_command_error(
              @http_transport.ServiceUnavailable,
              "durability_fenced",
            ),
          )
        }
      RunCommand(operation_id, _) =>
        self.strict_delete_failed(operation_id, "durability_fenced")
    }
    return
  }
  match event {
    SubmitCommand(ticket, spec, actor) =>
      self.accept_management_command(ticket, spec, actor)
    RunCommand(operation_id, spec) => {
      if self.strict.unwrap().has_pending() ||
        self.strict_checkpoint_cursor is Some(_) ||
        self.strict_checkpoint_inflight {
        if self.strict_management_held.length() >=
          self.runtime.config.max_runtime_events() {
          self.strict_delete_failed(operation_id, "capacity_exhausted")
        } else {
          self.strict_management_held.push_back(event)
        }
        return
      }
      match spec.kind {
        @management.DeleteSession =>
          self.run_strict_management_delete(operation_id, spec)
        @management.Kick => self.run_management_kick(operation_id, spec)
        @management.Reload =>
          self.strict_delete_failed(operation_id, "requires_restart")
      }
    }
  }
}
