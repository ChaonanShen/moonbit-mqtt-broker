///|
fn management_command_error(
  status : @http_transport.HttpStatus,
  code : String,
) -> ManagementCommandReply {
  let error : Map[String, Json] = Map([("code", code.to_json())])
  let body : Map[String, Json] = Map([("error", error.to_json())])
  { status, body: @utf8.encode(body.to_json().stringify()), location: None }
}

///|
fn management_operation_reply(
  record : @management.OperationRecord,
  status : @http_transport.HttpStatus,
) -> ManagementCommandReply {
  {
    status,
    body: @utf8.encode(record.to_json().stringify()),
    location: Some("/v1/operations/" + record.id),
  }
}

///|
fn RouterDriver::precheck_delete(
  self : RouterDriver,
  spec : @management.CommandSpec,
  active : ManagementRuntime,
) -> ManagementCommandReply? {
  let etag = match @management.parse_strong_etag(spec.if_match, "s") {
    Ok(value) => value
    Err(_) =>
      return Some(
        management_command_error(@http_transport.BadRequest, "bad_request"),
      )
  }
  if etag.boot_id != active.context.boot_id {
    return Some(
      management_command_error(
        @http_transport.PreconditionFailed,
        "precondition_failed",
      ),
    )
  }
  let handle = etag.target
  let view = match self.runtime.broker_state().admin_session_view(handle) {
    Some(value) => value
    None =>
      return Some(
        management_command_error(@http_transport.NotFound, "not_found"),
      )
  }
  if spec.if_match !=
    @management.session_etag(
      active.context.boot_id,
      handle,
      view.lifecycle_version,
    ) {
    return Some(
      management_command_error(
        @http_transport.PreconditionFailed,
        "precondition_failed",
      ),
    )
  }
  if view.attached || view.mode != "persistent" {
    return Some(
      management_command_error(@http_transport.Conflict, "session_active"),
    )
  }
  None
}

///|
fn RouterDriver::precheck_kick(
  self : RouterDriver,
  spec : @management.CommandSpec,
  active : ManagementRuntime,
) -> ManagementCommandReply? {
  let etag = match @management.parse_strong_etag(spec.if_match, "c") {
    Ok(value) => value
    Err(_) =>
      return Some(
        management_command_error(@http_transport.BadRequest, "bad_request"),
      )
  }
  if etag.boot_id != active.context.boot_id {
    return Some(
      management_command_error(
        @http_transport.PreconditionFailed,
        "precondition_failed",
      ),
    )
  }
  let id = ConnectionId::new(etag.target)
  let view = match self.management_connection_view(etag.target) {
    Some(value) => value
    None =>
      return Some(
        management_command_error(@http_transport.NotFound, "not_found"),
      )
  }
  if spec.if_match !=
    @management.connection_etag(active.context.boot_id, view.connection_id) {
    return Some(
      management_command_error(
        @http_transport.PreconditionFailed,
        "precondition_failed",
      ),
    )
  }
  if self.management_closing.contains(id) {
    return Some(
      management_command_error(@http_transport.Conflict, "connection_closing"),
    )
  }
  if self.management_closing.length() + active.pending_kick_reservations >=
    active.config.max_running_operations() {
    return Some(
      management_command_error(
        @http_transport.TooManyRequests,
        "capacity_exhausted",
      ),
    )
  }
  None
}

///|

///|
fn RouterDriver::accept_management_command(
  self : RouterDriver,
  ticket : ManagementCommandTicket,
  spec : @management.CommandSpec,
  actor : @management.AdminPrincipal,
) -> Unit {
  let active = match self.management {
    Some(value) => value
    None => return
  }
  let mailbox = match active.command_mailbox {
    Some(value) => value
    None => return
  }
  if !mailbox.valid(ticket) {
    return
  }
  if actor.token_id() != spec.actor_token_id ||
    !actor.allows(@management.Operator) {
    mailbox.produce(
      ticket,
      management_command_error(@http_transport.Forbidden, "forbidden"),
    )
    return
  }
  if active.context.lifecycle != @management.Serving {
    mailbox.produce(
      ticket,
      management_command_error(
        @http_transport.ServiceUnavailable,
        "unavailable",
      ),
    )
    return
  }
  if !active.config.operations_enabled() {
    mailbox.produce(
      ticket,
      management_command_error(
        @http_transport.ServiceUnavailable,
        "operations_disabled",
      ),
    )
    return
  }
  if !self.runtime.broker_state().management_index_available() ||
    !self.management_connection_index_available() {
    mailbox.produce(
      ticket,
      management_command_error(
        @http_transport.ServiceUnavailable,
        "details_unavailable",
      ),
    )
    return
  }
  let table = match active.operations {
    Some(value) => value
    None => return
  }
  let fingerprint = spec.normalized()
  match
    table.lookup_key(spec.actor_token_id, spec.idempotency_key, fingerprint) {
    @management.KeyMatch(record) => {
      mailbox.produce(
        ticket,
        management_operation_reply(
          record,
          if record.state == @management.Succeeded ||
            record.state == @management.Failed {
            @http_transport.Ok
          } else {
            @http_transport.Accepted
          },
        ),
      )
      return
    }
    @management.KeyConflict => {
      mailbox.produce(
        ticket,
        management_command_error(
          @http_transport.Conflict,
          "idempotency_conflict",
        ),
      )
      return
    }
    @management.KeyUnused => ()
  }
  if spec.kind == @management.Kick {
    if self.precheck_kick(spec, active) is Some(error) {
      mailbox.produce(ticket, error)
      return
    }
  }
  if spec.kind == @management.DeleteSession {
    if self.precheck_delete(spec, active) is Some(error) {
      mailbox.produce(ticket, error)
      return
    }
  }
  let now_monotonic = @budget.monotonic_ms()
  if now_monotonic < 0L {
    mailbox.produce(
      ticket,
      management_command_error(
        @http_transport.ServiceUnavailable,
        "unavailable",
      ),
    )
    return
  }
  let now_wall = @async.now()
  let mode = if self.strict is Some(_) {
    "strict"
  } else if active.persistence is Some(_) {
    "snapshot"
  } else {
    "off"
  }
  let record = match
    table.insert(
      spec.actor_token_id,
      spec.kind,
      spec.target,
      fingerprint,
      spec.idempotency_key,
      mode,
      now_wall,
      now_monotonic + active.config.operation_timeout_ms().to_int64(),
    ) {
    Ok(value) => value
    Err(@management.OperationCapacity) =>
      return mailbox.produce(
        ticket,
        management_command_error(
          @http_transport.TooManyRequests,
          "capacity_exhausted",
        ),
      )
    Err(_) =>
      return mailbox.produce(
        ticket,
        management_command_error(
          @http_transport.ServiceUnavailable,
          "unavailable",
        ),
      )
  }
  if !mailbox.schedule_run(record.id, spec) {
    ignore(table.discard_unstarted(record.id))
    mailbox.produce(
      ticket,
      management_command_error(
        @http_transport.TooManyRequests,
        "capacity_exhausted",
      ),
    )
    return
  }
  let audited = match active.audit {
    Some(ring) =>
      ring.append({
        sequence: 0L,
        timestamp_ms: now_wall,
        actor_token_id: spec.actor_token_id,
        operation_id: record.id,
        kind: spec.kind,
        target: spec.target,
        phase: "accepted",
        result: "accepted",
        effect_applied: false,
        state_revision: None,
      })
    None => false
  }
  if !audited {
    ignore(table.discard_unstarted(record.id))
    mailbox.produce(
      ticket,
      management_command_error(
        @http_transport.ServiceUnavailable,
        "unavailable",
      ),
    )
    return
  }
  if spec.kind == @management.Kick {
    active.pending_kick_reservations += 1
  }
  mailbox.produce(
    ticket,
    management_operation_reply(record, @http_transport.Accepted),
  )
}

///|
fn RouterDriver::run_management_delete(
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
  let now_monotonic = @budget.monotonic_ms()
  if now_monotonic >= record.deadline_monotonic_ms {
    ignore(
      table.finish(
        operation_id,
        false,
        false,
        false,
        true,
        Some("timeout"),
        None,
        None,
        @async.now(),
        now_monotonic,
      ),
    )
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
    Err(_) => return
  }
  let version = etag.lifecycle_version.unwrap()
  let result = self.runtime
    .broker_state()
    .admin_delete_offline(etag.target, version)
  let mut succeeded = false
  let mut effect_applied = false
  let mut error_code : String? = None
  match result {
    Ok(actions) => {
      effect_applied = true
      self.dispatch(self.runtime.map_broker_actions(actions))
      self.runtime.admission.prune_publishers(self.runtime.broker_state())
      ignore(self.poll_snapshot(@async.now()))
      succeeded = true
    }
    Err(@router.AdminNotFound) => error_code = Some("not_found")
    Err(@router.AdminPreconditionFailed) =>
      error_code = Some("precondition_failed")
    Err(@router.AdminSessionActive) => error_code = Some("session_active")
    Err(@router.AdminDetailsUnavailable) =>
      error_code = Some("details_unavailable")
    Err(@router.AdminInvariantViolation) =>
      error_code = Some("invariant_violation")
  }
  let revision = if effect_applied {
    Some(self.runtime.broker_state().snapshot_revision())
  } else {
    None
  }
  let committed = match active.persistence {
    Some(value) => {
      let revision = value.committed_revision()
      if revision >= 0L {
        Some(revision)
      } else {
        None
      }
    }
    None => None
  }
  let now_wall = @async.now()
  ignore(
    table.finish(
      operation_id,
      succeeded,
      effect_applied,
      false,
      false,
      error_code,
      revision,
      committed,
      now_wall,
      @budget.monotonic_ms(),
    ),
  )
  if active.audit is Some(ring) {
    ignore(
      ring.append({
        sequence: 0L,
        timestamp_ms: now_wall,
        actor_token_id: spec.actor_token_id,
        operation_id,
        kind: @management.DeleteSession,
        target: spec.target,
        phase: if succeeded {
          "completed"
        } else {
          "failed"
        },
        result: if succeeded {
          "succeeded"
        } else {
          error_code.unwrap_or("failed")
        },
        effect_applied,
        state_revision: revision,
      }),
    )
  }
}

///|
fn RouterDriver::handle_management_command(
  self : RouterDriver,
  event : ManagementCommandEvent,
) -> Unit {
  match event {
    SubmitCommand(ticket, spec, actor) =>
      self.accept_management_command(ticket, spec, actor)
    RunCommand(operation_id, spec) =>
      match spec.kind {
        @management.DeleteSession =>
          self.run_management_delete(operation_id, spec)
        @management.Kick => self.run_management_kick(operation_id, spec)
        @management.Reload => ()
      }
  }
}
