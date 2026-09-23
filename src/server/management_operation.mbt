///|
priv struct ManagementKickWatch {
  operation_id : String
  signal_sent : Bool
  mut terminal_seen : Bool
  mut unregistered : Bool
  mut timed_out : Bool
}

///|
fn RouterDriver::track_auth_association(
  self : RouterDriver,
  task_id : Int64,
  connection_id : ConnectionId,
) -> Unit {
  self.auth_task_connection.set(task_id, connection_id)
  self.auth_outstanding.set(
    connection_id,
    self.auth_outstanding.get(connection_id).unwrap_or(0) + 1,
  )
}

///|
/// Only call at executor submit failure/unknown or actual reap completion.
fn RouterDriver::clear_auth_association(
  self : RouterDriver,
  task_id : Int64,
) -> Unit {
  match self.auth_task_connection.get(task_id) {
    None => ()
    Some(connection_id) => {
      self.auth_task_connection.remove(task_id)
      let previous = self.auth_outstanding.get(connection_id).unwrap_or(0)
      if previous <= 1 {
        self.auth_outstanding.remove(connection_id)
      } else {
        self.auth_outstanding.set(connection_id, previous - 1)
      }
    }
  }
}

///|
fn RouterDriver::finish_management_kick(
  self : RouterDriver,
  watch : ManagementKickWatch,
) -> Unit {
  let active = match self.management {
    Some(value) => value
    None => return
  }
  let table = match active.operations {
    Some(value) => value
    None => return
  }
  let record = match table.get_internal(watch.operation_id) {
    Some(value) => value
    None => return
  }
  let revision = Some(self.runtime.broker_state().snapshot_revision())
  let committed = active.persistence.map(value => value.committed_revision())
  let now_wall = @async.now()
  ignore(
    table.finish(
      watch.operation_id,
      true,
      watch.signal_sent,
      true,
      watch.timed_out,
      if watch.signal_sent {
        None
      } else {
        Some("already_closed")
      },
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
        actor_token_id: record.actor_token_id,
        operation_id: watch.operation_id,
        kind: @management.Kick,
        target: record.target,
        phase: "completed",
        result: if watch.signal_sent {
          "succeeded"
        } else {
          "already_closed"
        },
        effect_applied: watch.signal_sent,
        state_revision: revision,
      }),
    )
  }
}

///|
/// Each poll inspects only the bounded running watch table. Terminal/driver
/// unregister and actual auth executor reap are all required before success.
fn RouterDriver::poll_management_kicks(self : RouterDriver) -> Unit {
  if self.management_closing.length() == 0 {
    return
  }
  let now = @budget.monotonic_ms()
  let completed : Array[ConnectionId] = []
  for id, watch in self.management_closing {
    if !watch.timed_out &&
      self.management is Some(active) &&
      active.operations is Some(table) &&
      table.get_internal(watch.operation_id) is Some(record) &&
      now >= record.deadline_monotonic_ms {
      watch.timed_out = true
      ignore(table.replace({ ..record, timed_out: true }))
    }
    if watch.terminal_seen &&
      watch.unregistered &&
      !self.sinks.contains(id) &&
      !self.runtime.has_connection(id) {
      if self.auth_outstanding.get(id).unwrap_or(0) == 0 {
        self.finish_management_kick(watch)
        completed.push(id)
      } else if self.management is Some(active) &&
        active.operations is Some(table) &&
        table.get_internal(watch.operation_id) is Some(record) &&
        record.stage != @management.WaitingAuthReap {
        ignore(table.replace({ ..record, stage: @management.WaitingAuthReap }))
      }
    }
  }
  for id in completed {
    self.management_closing.remove(id)
  }
}

///|
fn RouterDriver::run_management_kick(
  self : RouterDriver,
  operation_id : String,
  spec : @management.CommandSpec,
) -> Unit {
  let active = match self.management {
    Some(value) => value
    None => return
  }
  if active.pending_kick_reservations > 0 {
    active.pending_kick_reservations -= 1
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
  let id_value = @string.parse_int64(spec.target) catch { _ => return }
  let id = ConnectionId::new(id_value)
  let view = self.management_connection_view(id_value)
  let current_etag = @management.connection_etag(
    active.context.boot_id,
    id_value,
  )
  if view is Some(_) && spec.if_match != current_etag {
    ignore(
      table.finish(
        operation_id,
        false,
        false,
        false,
        false,
        Some("precondition_failed"),
        None,
        None,
        @async.now(),
        now_monotonic,
      ),
    )
    return
  }
  if self.management_closing.length() >= active.config.max_running_operations() {
    ignore(
      table.finish(
        operation_id,
        false,
        false,
        false,
        false,
        Some("capacity_exhausted"),
        None,
        None,
        @async.now(),
        now_monotonic,
      ),
    )
    return
  }
  let has_sink = self.sinks.get(id) is Some(_)
  let has_runtime = self.runtime.has_connection(id)
  let watch : ManagementKickWatch = {
    operation_id,
    signal_sent: has_sink,
    terminal_seen: !has_runtime,
    unregistered: !has_sink,
    timed_out: false,
  }
  self.management_closing.set(id, watch)
  let started_at = @async.now()
  ignore(table.start(operation_id, @management.ClosingTransport, started_at))
  if active.audit is Some(ring) {
    ignore(
      ring.append({
        sequence: 0L,
        timestamp_ms: started_at,
        actor_token_id: spec.actor_token_id,
        operation_id,
        kind: @management.Kick,
        target: spec.target,
        phase: "started",
        result: "running",
        effect_applied: false,
        state_revision: None,
      }),
    )
  }
  if self.sinks.get(id) is Some(sink) {
    sink.resolve_handshake(false)
    sink.try_close(AdminKick)
  }
}
