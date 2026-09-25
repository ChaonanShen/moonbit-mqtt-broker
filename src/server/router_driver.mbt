///|
priv struct StrictReloadPending {
  candidate : PreparedReload
  expected_epoch : Int64
  reply : @async.Queue[ReloadDriverReply]
  mut committed : Bool
}

///|
pub struct RouterDriver {
  runtime : BrokerRuntime
  sinks : Map[ConnectionId, TransportSink]
  priv mut management_connections : @slot_index.SlotIndex?
  priv mut management_connections_available : Bool
  priv snapshot : SnapshotDriverState?
  priv strict : CommitCoordinator?
  priv strict_generations : Map[@session.ClientId, Int64]
  priv strict_held : @deque.Deque[(RuntimeEvent, @budget.Ticket?)]
  priv strict_held_connections : Map[ConnectionId, Int]
  priv strict_management_held : @deque.Deque[ManagementCommandEvent]
  priv mut strict_fenced : Bool
  priv mut reload_barrier : Bool
  priv generation : GenerationHandle?
  priv material_provider : TlsMaterialProvider?
  priv mut retired_generations : Array[ConfigGeneration]
  priv mut reload_reconciler : @router.PolicyReconciler?
  priv mut reload_connection_slot : Int?
  priv mut reload_issue : @router.PolicyIssue?
  priv mut strict_reload_pending : StrictReloadPending?
  priv reload_service : ReloadService?
  priv reload_reconcile_items : Int
  priv reload_reconcile_bytes : Int64
  priv mut strict_checkpoint_cursor : @router.SnapshotExportCursor?
  priv mut strict_checkpoint_lsn : Int64
  priv mut strict_checkpoint_inflight : Bool
  priv mut strict_checkpoint_next_ms : Int64
  priv mut strict_checkpoint_degraded : Bool
  priv auth_executor : @security.AuthExecutor?
  priv mut auth_infrastructure : @budget.Ticket?
  priv auth_cancels : Map[Int64, Bool]
  priv auth_reaps : Map[Int64, Bool]
  priv auth_task_connection : Map[Int64, ConnectionId]
  priv auth_outstanding : Map[ConnectionId, Int]
  priv management_closing : Map[ConnectionId, ManagementKickWatch]
  priv mut last_progress_monotonic_ms : Int64
  priv management : ManagementRuntime?
}

///|
pub struct SnapshotDriverConfig {
  sink : @persistence.SnapshotSink
  debounce_ms : Int64
  max_delay_ms : Int64
}

///|
priv struct SnapshotDriverState {
  mut oldest_uncommitted_ms : Int64?
  mut budget_deferred : Int64
  mut last_budget_log_ms : Int64
  sink : @persistence.SnapshotSink
  schedule : SnapshotSchedule
}

///|
pub fn SnapshotDriverConfig::new(
  sink : @persistence.SnapshotSink,
  debounce_ms : Int64,
  max_delay_ms : Int64,
) -> Result[SnapshotDriverConfig, @persistence.PersistenceError] {
  match SnapshotSchedule::new(0L, debounce_ms, max_delay_ms) {
    Ok(_) => Ok({ sink, debounce_ms, max_delay_ms })
    Err(error) => Err(error)
  }
}

///|
pub fn RouterDriver::new(
  runtime : BrokerRuntime,
  snapshot? : SnapshotDriverConfig,
  auth_executor? : @security.AuthExecutor,
  auth_infrastructure? : @budget.Ticket,
  management? : ManagementRuntime,
  strict? : CommitCoordinator,
  strict_generations? : Map[@session.ClientId, Int64] = Map([]),
  generation? : GenerationHandle,
  material_provider? : TlsMaterialProvider,
  reload_reconcile_items? : Int = 64,
  reload_reconcile_bytes? : Int64 = 1048576L,
  reload_service? : ReloadService,
) -> RouterDriver {
  let snapshot = snapshot.map(config => SnapshotDriverState::{
    oldest_uncommitted_ms: None,
    budget_deferred: 0L,
    last_budget_log_ms: 0L,
    sink: config.sink,
    schedule: SnapshotSchedule::new(
      runtime.broker_state().snapshot_revision(),
      config.debounce_ms,
      config.max_delay_ms,
    ).unwrap(),
  })
  {
    runtime,
    sinks: Map([]),
    management_connections: None,
    management_connections_available: true,
    snapshot,
    strict,
    strict_generations,
    strict_held: @deque.Deque([]),
    strict_held_connections: Map([]),
    strict_management_held: @deque.Deque([]),
    strict_fenced: false,
    reload_barrier: false,
    generation,
    material_provider,
    retired_generations: [],
    reload_reconciler: None,
    reload_connection_slot: None,
    reload_issue: None,
    strict_reload_pending: None,
    reload_service,
    reload_reconcile_items,
    reload_reconcile_bytes,
    strict_checkpoint_cursor: None,
    strict_checkpoint_lsn: 0L,
    strict_checkpoint_inflight: false,
    strict_checkpoint_next_ms: @async.now() + 60000L,
    strict_checkpoint_degraded: false,
    auth_executor,
    auth_infrastructure,
    auth_cancels: Map([]),
    auth_reaps: Map([]),
    auth_task_connection: Map([]),
    auth_outstanding: Map([]),
    management_closing: Map([]),
    last_progress_monotonic_ms: @budget.monotonic_ms(),
    management,
  }
}

///|
/// The single writer stops admitting new business while older transactions
/// drain and the policy record is committed. A failed entry leaves the driver
/// untouched; the barrier is released only after activation or final failure.
pub fn RouterDriver::begin_reload_barrier(self : RouterDriver) -> Bool {
  let coordinator = match self.strict {
    Some(value) if !self.strict_fenced && !value.is_fenced() => value
    _ => return false
  }
  if self.reload_barrier ||
    self.strict_checkpoint_cursor is Some(_) ||
    self.strict_checkpoint_inflight {
    return false
  }
  if coordinator.is_collecting() && !coordinator.flush() {
    self.strict_fence("reload-barrier-flush")
    return false
  }
  self.reload_barrier = true
  true
}

///|
pub fn RouterDriver::reload_barrier_ready(self : RouterDriver) -> Bool {
  let coordinator = match self.strict {
    Some(value) => value
    None => return false
  }
  self.reload_barrier &&
  !self.strict_fenced &&
  !coordinator.is_fenced() &&
  !coordinator.has_pending() &&
  self.strict_checkpoint_cursor is None &&
  !self.strict_checkpoint_inflight
}

///|
pub fn RouterDriver::end_reload_barrier(self : RouterDriver) -> Unit {
  if !self.reload_barrier {
    return
  }
  self.reload_barrier = false
  self.drain_strict_queues()
}

///|
pub fn RouterDriver::runtime(self : RouterDriver) -> BrokerRuntime {
  self.runtime
}

///|
pub fn RouterDriver::transport_count(self : RouterDriver) -> Int {
  self.sinks.length()
}

///|
fn RouterDriver::submit_snapshot(
  self : RouterDriver,
  state : SnapshotDriverState,
  revision : Int64,
) -> Bool {
  let ledger = self.runtime.broker_state().resource_ledger()
  let limit = self.runtime.config
    .broker_config()
    .resources()
    .get("max_snapshot_work_bytes")
  let pool = ledger.pool(Snapshot, limit).unwrap()
  let cost = match self.runtime.broker_state().snapshot_work_cost() {
    Ok(cost) => cost
    Err(_) => {
      self.snapshot_deferred(state)
      return false
    }
  }
  let ticket = match pool.reserve(cost) {
    Ok(t) => t
    Err(_) => {
      self.snapshot_deferred(state)
      return false
    }
  }
  let snapshot = self.runtime.broker_state().export_snapshot()
  ticket.commit().unwrap()
  let submitted = state.sink.submit_accounted({ revision, snapshot }, ticket)
  if !submitted {
    ticket.release().unwrap()
  }
  if submitted {
    state.schedule.mark_submitted(revision)
  }
  submitted
}

///|
pub fn RouterDriver::poll_snapshot(self : RouterDriver, now_ms : Int64) -> Bool {
  match self.snapshot {
    None => false
    Some(state) => {
      let revision = self.runtime.broker_state().snapshot_revision()
      if revision > 0L && revision > state.sink.committed_revision() {
        if state.oldest_uncommitted_ms is None {
          state.oldest_uncommitted_ms = Some(now_ms)
        }
        let age = now_ms - state.oldest_uncommitted_ms.unwrap()
        self.runtime.metrics.snapshot_dirty_age_ms = if age < 0L {
          0L
        } else {
          age
        }
      } else {
        state.oldest_uncommitted_ms = None
        self.runtime.metrics.snapshot_dirty_age_ms = 0L
      }
      state.schedule.observe(
        self.runtime.broker_state().snapshot_revision(),
        now_ms,
      )
      match state.schedule.due_revision(now_ms) {
        Some(revision) => self.submit_snapshot(state, revision)
        None => false
      }
    }
  }
}

///|
pub fn RouterDriver::force_snapshot(self : RouterDriver) -> Bool {
  match self.snapshot {
    None => false
    Some(state) => {
      state.schedule.observe(
        self.runtime.broker_state().snapshot_revision(),
        @async.now(),
      )
      match state.schedule.force_revision() {
        Some(revision) => self.submit_snapshot(state, revision)
        None => false
      }
    }
  }
}

///|

///|
fn TransportSink::try_close(self : TransportSink, reason : CloseReason) -> Unit {
  ignore(self.close_signal.try_put(reason)) catch {
    _ => ()
  }
}

///|
fn RouterDriver::transport_failed(
  self : RouterDriver,
  connection_id : ConnectionId,
  reason : CloseReason,
) -> Array[RuntimeAction] {
  if self.management_closing.contains(connection_id) {
    if self.sinks.get(connection_id) is Some(sink) {
      sink.try_close(reason)
    }
    return []
  }
  if self.strict is Some(_) {
    self.handle_strict_runtime_event(
      TransportClosed({ connection_id, reason, observed_at_ms: 0L }),
      None,
    )
    return []
  }
  self.runtime.apply(
    TransportClosed({ connection_id, reason, observed_at_ms: 0L }),
  )
}

///|
fn RouterDriver::retry_auth_control(self : RouterDriver) -> Unit {
  let executor = match self.auth_executor {
    Some(value) => value
    None => return
  }
  let cancel_ids : Array[Int64] = []
  for request_id, _ in self.auth_cancels {
    cancel_ids.push(request_id)
  }
  for request_id in cancel_ids {
    match executor.cancel(request_id) {
      CancelRetryLater => ()
      CancelUnknown => {
        self.auth_cancels.remove(request_id)
        self.clear_auth_association(request_id)
        let completed = AuthenticationCompleted({
          request_id,
          outcome: @security.AuthCompletionOutcome::AuthInternalFailure,
          completed_at_ms: @async.now(),
        })
        if self.strict is Some(_) {
          self.handle_strict_runtime_event(completed, None)
        } else {
          self.dispatch(self.runtime.apply(completed))
        }
      }
      _ => self.auth_cancels.remove(request_id)
    }
  }
  let reap_ids : Array[Int64] = []
  for request_id, _ in self.auth_reaps {
    reap_ids.push(request_id)
  }
  for request_id in reap_ids {
    match executor.reap(request_id) {
      ControlRetryLater | ControlStillRunning => ()
      _ => {
        self.auth_reaps.remove(request_id)
        self.clear_auth_association(request_id)
      }
    }
  }
}

///|
fn RouterDriver::poll_authentication(self : RouterDriver) -> Unit {
  let executor = match self.auth_executor {
    Some(value) => value
    None => return
  }
  self.retry_auth_control()
  for _ in 0..<self.runtime.config.auth_result_batch_limit() {
    match executor.poll() {
      NoCompletion | PollRetryLater | PollInvalid => return
      Completion(completed) => {
        let outcome = match self.auth_task_connection.get(completed.task_id) {
          Some(connection_id) if self.management_closing.contains(connection_id) =>
            @security.AuthCompletionOutcome::AuthInternalFailure
          _ => completed.outcome
        }
        let completed_event = AuthenticationCompleted({
          request_id: completed.task_id,
          outcome,
          completed_at_ms: @async.now(),
        })
        if self.strict is Some(_) {
          self.handle_strict_runtime_event(completed_event, None)
        } else {
          self.dispatch(self.runtime.apply(completed_event))
        }
        match executor.reap(completed.task_id) {
          ControlDone | ControlInvalid =>
            self.clear_auth_association(completed.task_id)
          ControlRetryLater | ControlStillRunning => {
            self.auth_reaps.set(completed.task_id, true)
            return
          }
        }
      }
    }
  }
}

///|
pub async fn RouterDriver::shutdown_authentication(self : RouterDriver) -> Unit {
  let executor = match self.auth_executor {
    Some(value) => value
    None => return
  }
  self.runtime.broker_state().begin_action_scope()
  self.dispatch(self.runtime.cancel_authenticating_connections(ServerShutdown))
  self.runtime.broker_state().end_action_scope()
  let mut stop_requested = false
  let shutdown_started = @async.now()
  let mut grace_reported = false
  for ;; {
    self.runtime.broker_state().begin_action_scope()
    if !stop_requested {
      match executor.stop() {
        ControlDone => stop_requested = true
        ControlRetryLater => ()
        ControlInvalid | ControlStillRunning => stop_requested = true
      }
    }
    self.poll_authentication()
    self.runtime.broker_state().end_action_scope()
    let stopped = executor.is_stopped() == Some(true)
    if stopped &&
      self.runtime.auth_task_count() == 0 &&
      self.auth_reaps.length() == 0 {
      match executor.destroy() {
        ControlDone => {
          release_optional(self.auth_infrastructure)
          self.auth_infrastructure = None
          return
        }
        _ => ()
      }
    }
    let now_ms = @async.now()
    if !grace_reported &&
      now_ms - shutdown_started >=
      self.runtime.config.auth_shutdown_grace_ms().to_int64() {
      grace_reported = true
      self.runtime.logger.log(
        @observability.LogRecord::new(
          now_ms,
          @observability.Warn,
          "auth_shutdown_grace_elapsed",
          reason="native_auth_still_draining",
          message="authentication workers remain owned and will continue draining",
        ),
      )
    }
    @async.sleep(self.runtime.config.auth_poll_interval_ms())
  }
}

///|
fn RouterDriver::dispatch(
  self : RouterDriver,
  initial : Array[RuntimeAction],
) -> Unit {
  let worklist = initial.copy()
  let mut index = 0
  while index < worklist.length() {
    let action = worklist[index]
    index = index + 1
    match action {
      SendPacket(send) =>
        if self.sinks.get(send.connection_id) is Some(sink) {
          match
            self.encode_and_queue(
              sink,
              send.packet,
              None,
              connection_id=send.connection_id,
            ) {
            Err(reason) => {
              if send.packet is Connack(_) {
                sink.resolve_handshake(false)
              }
              worklist.append(self.transport_failed(send.connection_id, reason))
            }
            Ok(_) =>
              if send.packet is Connack(connack) {
                sink.resolve_handshake(
                  connack.return_code == @protocol.ConnectReturnCode::Accepted,
                )
              }
          }
        }
      SendPacketThenClose(send) =>
        if self.sinks.get(send.connection_id) is Some(sink) {
          let result = self.encode_and_queue(
            sink,
            send.packet,
            Some(send.reason),
            connection_id=send.connection_id,
          )
          if send.packet is Connack(_) {
            sink.resolve_handshake(false)
          }
          if result is Err(reason) {
            sink.try_close(reason)
            worklist.append(self.transport_failed(send.connection_id, reason))
          }
        }
      SendMqtt5(send) =>
        if self.sinks.get(send.connection_id) is Some(sink) {
          let result = self.encode_v5_and_queue(
            sink,
            send.packet,
            send.close_reason,
          )
          if send.packet is @protocol.PacketV5::Connack5(connack) {
            sink.resolve_handshake(result is Ok(_) && connack.reason == 0)
          }
          if result is Err(reason) {
            worklist.append(self.transport_failed(send.connection_id, reason))
          }
        }
      CloseTransport(close) =>
        match self.sinks.get(close.connection_id) {
          None => ()
          Some(sink) => {
            sink.resolve_handshake(false)
            sink.try_close(close.reason)
          }
        }
      StartAuthentication(start) => {
        let connection_id = self.runtime.auth_tasks
          .get(start.request_id)
          .map(task => task.connection_id)
        let failed = match
          (
            self.auth_executor,
            self.runtime.take_auth_submission(start.request_id),
          ) {
          (Some(executor), Some(request)) =>
            executor.submit(start.request_id, request) !=
            @security.AuthSubmitResult::Submitted
          _ => true
        }
        if failed {
          worklist.append(
            self.runtime.apply(AuthenticationSubmitFailed(start.request_id)),
          )
        } else if connection_id is Some(id) {
          self.track_auth_association(start.request_id, id)
        }
      }
      StartDurableWill(connection_id) => {
        let pending = match
          self.runtime.take_strict_pending_will(connection_id) {
          Some(value) => value
          None => continue
        }
        let (client_id, will, ticket) = pending
        let coordinator = match self.strict {
          Some(value) if !self.strict_fenced => value
          _ => {
            release_optional(ticket)
            continue
          }
        }
        let input : @router.PublishInput = {
          origin: Will(client_id),
          topic: will.topic,
          payload: will.payload,
          qos: will.qos,
          retain: will.retain,
        }
        let plan = match
          self.runtime
          .broker_state()
          .prepare_durable_publish(input, self.strict_generations) {
          Ok(value) => Some(value)
          Err(_) if will.retain =>
            match
              self.runtime
              .broker_state()
              .prepare_durable_publish(
                { ..input, retain: false },
                self.strict_generations,
              ) {
              Ok(value) => Some(value)
              Err(_) => None
            }
          Err(_) => None
        }
        match plan {
          None => {
            self.runtime.metrics.record_dropped()
            release_optional(ticket)
          }
          Some(value) => {
            let submitted = coordinator.submit(
              PublishWithWill(value, ticket),
              broker_actions => {
                release_optional(ticket)
                self.runtime.map_broker_actions(broker_actions)
              },
              connection_id~,
            )
            match submitted {
              Ok(_) => ()
              Err(CommitEncoding) | Err(CommitBudget) =>
                self.runtime.metrics.record_dropped()
              Err(_) => self.strict_fence("will-submit")
            }
          }
        }
      }
      CancelAuthentication(cancel) =>
        match self.auth_executor {
          None =>
            worklist.append(
              self.runtime.apply(
                AuthenticationCompleted({
                  request_id: cancel.request_id,
                  outcome: @security.AuthCompletionOutcome::AuthInternalFailure,
                  completed_at_ms: @async.now(),
                }),
              ),
            )
          Some(executor) =>
            match executor.cancel(cancel.request_id) {
              CancelRetryLater => self.auth_cancels.set(cancel.request_id, true)
              CancelUnknown => {
                self.clear_auth_association(cancel.request_id)
                worklist.append(
                  self.runtime.apply(
                    AuthenticationCompleted({
                      request_id: cancel.request_id,
                      outcome: @security.AuthCompletionOutcome::AuthInternalFailure,
                      completed_at_ms: @async.now(),
                    }),
                  ),
                )
              }
              _ => ()
            }
        }
    }
  }
}

///|
pub fn RouterDriver::handle(self : RouterDriver, event : DriverEvent) -> Unit {
  match event {
    ReloadControl(command) => self.handle_reload_control(command)
    _ => self.handle_scoped(event)
  }
  self.finish_committed_reload()
  self.advance_reload_reconciliation()
}

///|
fn RouterDriver::handle_scoped(
  self : RouterDriver,
  event : DriverEvent,
) -> Unit {
  self.runtime.broker_state().begin_action_scope()
  defer {
    let completed = @budget.monotonic_ms()
    self.last_progress_monotonic_ms = completed
    if self.management is Some(active) {
      active.cache.update_driver_progress(completed)
      active.availability.details_available = active.config.details_enabled() &&
        self.runtime.broker_state().management_index_available() &&
        self.management_connection_index_available()
    }
  }
  defer self.runtime.broker_state().end_action_scope()
  match event {
    Accounted(event, ticket) =>
      if self.strict is Some(_) {
        self.handle_strict_runtime_event(event, Some(ticket))
      } else {
        defer ticket.release().unwrap()
        self.handle_runtime_event(event)
      }
    RegisterTransport(register) => {
      if self.strict_fenced {
        register.sink.resolve_handshake(false)
        register.sink.try_close(ServerShutdown)
        return
      }
      if self.sinks.get(register.connection_id) is Some(_) {
        return
      }
      register.sink.set_writer_gate(authorization => {
        self.runtime.authorize_outbound(authorization)
      })
      self.sinks.set(register.connection_id, register.sink)
      if self.management_connections is Some(index) {
        if index.put(register.connection_id.value().to_string())
          is @slot_index.Full {
          self.management_connections_available = false
        }
      }
      self.dispatch(
        self.runtime.apply(
          TransportOpened({
            connection_id: register.connection_id,
            accepted_at_ms: register.accepted_at_ms,
          }),
        ),
      )
    }
    Runtime(event) =>
      if self.strict is Some(_) {
        self.handle_strict_runtime_event(event, None)
      } else {
        self.handle_runtime_event(event)
      }
    WalCompletionDue => ()
    WalFlushDue =>
      if self.strict is Some(coordinator) &&
        coordinator.is_collecting() &&
        !coordinator.flush() {
        self.strict_fence("group-commit-submit")
      }
    ObservationDue =>
      if self.management is Some(active) {
        let sampled_at = @budget.monotonic_ms()
        let persistence = active.persistence
        let sample = self.capture_observation(
          sampled_at,
          @async.now(),
          active.context,
          persistence?,
        )
        if !active.cache.publish(sample) {
          active.rejections.record(@management.RejectedOther)
        }
      }
    ManagementQuery(query) => self.handle_management_query(query)
    ManagementCommand(command) =>
      if self.strict is Some(_) {
        self.handle_strict_management_command(command)
      } else {
        self.handle_management_command(command)
      }
    ManagementMaintenance => self.maintain_management()
    ReloadControl(_) => abort("reload control entered scoped handler")
    UnregisterTransport(connection_id) => {
      self.sinks.remove(connection_id)
      if self.management_closing.get(connection_id) is Some(watch) {
        watch.unregistered = true
      }
      if self.management_connections is Some(index) &&
        !index.remove(connection_id.value().to_string()) {
        self.management_connections_available = false
      }
    }
  }
  self.poll_authentication()
  self.retire_released_generations()
  if self.strict is Some(_) {
    self.poll_strict_completion()
    if self.strict is Some(coordinator) &&
      coordinator.check_timeout(@async.now()) {
      self.strict_fence("commit-timeout")
    }
    self.poll_strict_checkpoint()
    self.poll_management_kicks()
  } else {
    self.poll_management_kicks()
    ignore(self.poll_snapshot(@async.now()))
  }
}

///|
pub async fn RouterDriver::run(
  self : RouterDriver,
  events : @async.Queue[DriverEvent],
) -> Unit {
  for ;; {
    let event = events.get() catch { _ => return }
    self.handle(event)
  }
}

///|
fn RouterDriver::handle_runtime_event(
  self : RouterDriver,
  event : RuntimeEvent,
) -> Unit {
  if event is Mqtt5PacketReceived(packet) {
    if packet.packet is @protocol.PacketV5::Connect5(_) &&
      self.runtime.connections.get(packet.connection_id)
      is Some({ phase: AwaitConnect, .. }) {
      if self.sinks.get(packet.connection_id) is Some(sink) &&
        !sink.prepare_handshake(
          self.runtime.config
          .broker_config()
          .resources()
          .get("control_reserve_bytes"),
          frame_bytes=5L,
          scratch_bytes=10L,
        ) {
        self.dispatch(
          self.transport_failed(packet.connection_id, ResourceExhausted),
        )
        return
      }
    }
  }
  if event is PacketReceived(packet) {
    if packet.packet is Connect(_) &&
      self.management_closing.contains(packet.connection_id) {
      return
    }
    if packet.packet is Connect(_) &&
      self.runtime.connections.get(packet.connection_id)
      is Some({ phase: AwaitConnect, .. }) {
      if self.sinks.get(packet.connection_id) is Some(sink) &&
        !sink.prepare_handshake(
          self.runtime.config
          .broker_config()
          .resources()
          .get("control_reserve_bytes"),
        ) {
        self.dispatch(
          self.transport_failed(packet.connection_id, ResourceExhausted),
        )
        return
      }
    }
    if self.runtime
      .broker_state()
      .admit_action_input(
        packet_cost(packet.packet) * 2L,
        control=control_packet(packet.packet),
      )
      is Err(_) {
      self.dispatch(
        self.transport_failed(packet.connection_id, ResourceExhausted),
      )
      return
    }
  }
  self.dispatch(self.runtime.apply(event))
  if event is TransportClosed(closed) &&
    self.management_closing.get(closed.connection_id) is Some(watch) {
    watch.terminal_seen = true
  }
  if event is CheckDeadlines(_) {
    self.runtime.admission.cleanup_ips((self.runtime.admission.clock)())
    self.runtime.admission.prune_publishers(self.runtime.broker_state())
    self.dispatch(
      self.runtime.map_broker_actions(
        self.runtime.broker_state().resume_pending(),
      ),
    )
  }
}

///|
fn RouterDriver::encode_v5_and_queue(
  self : RouterDriver,
  sink : TransportSink,
  packet : @protocol.PacketV5,
  close : CloseReason?,
) -> Result[Unit, CloseReason] {
  if packet is @protocol.PacketV5::Publish5(_) {
    return Err(EncodeFailure)
  }
  let frame = match
    @protocol.encode_v5(
      packet,
      @protocol.PacketDirection::ServerToClient,
      self.runtime.config.max_packet_size(),
    ) {
    Ok(value) => value
    Err(_) => return Err(EncodeFailure)
  }
  let prepared = if packet is @protocol.PacketV5::Connack5(_) {
    let value = sink.handshake
    sink.handshake = None
    value
  } else {
    None
  }
  let reservation = match prepared {
    Some((frame_reservation, scratch)) => {
      scratch.release().unwrap()
      Some(frame_reservation)
    }
    None =>
      match sink.reserve_frame(frame.length().to_int64(), true) {
        Ok(value) => value
        Err(_) => return Err(SlowConsumer)
      }
  }
  if sink.enqueue_frame(frame, reservation, close) {
    Ok(())
  } else {
    Err(SlowConsumer)
  }
}

///|
fn RouterDriver::encode_and_queue(
  self : RouterDriver,
  sink : TransportSink,
  packet : @protocol.Packet,
  close : CloseReason?,
  connection_id? : ConnectionId,
) -> Result[Unit, CloseReason] {
  let authorization : OutboundAuthorization? = match packet {
    Publish(value) =>
      match connection_id {
        None => None
        Some(id) => {
          let client_id = match self.runtime.connections.get(id) {
            Some({ phase: Active(value), .. }) => value
            _ => return Err(PolicyRevoked)
          }
          let topic = match @topic.TopicName::new(value.topic) {
            Ok(value) => value
            Err(_) => return Err(EncodeFailure)
          }
          let value : OutboundAuthorization = {
            connection_id: id,
            client_id,
            session_incarnation: self.runtime
            .broker_state()
            .policy_session_incarnation(client_id),
            topic,
          }
          if !self.runtime.authorize_outbound(value) {
            return Err(PolicyRevoked)
          }
          Some(value)
        }
      }
    _ => None
  }
  let bound = wire_cost_bound(packet)
  let charged = match
    @budget.checked_add(
      bound,
      authorization.map(value => value.cost()).unwrap_or(0L),
    ) {
    Ok(value) => value
    Err(_) => return Err(ResourceExhausted)
  }
  let prepared = if packet is Connack(_) {
    let value = sink.handshake
    sink.handshake = None
    value
  } else {
    None
  }
  let (ticket, temporary) = match prepared {
    Some((frame, scratch)) => (Some(frame), Some(scratch))
    None => {
      let ticket = match sink.reserve_frame(charged, control_packet(packet)) {
        Ok(t) => t
        Err(_) => return Err(SlowConsumer)
      }
      let temporary = match sink.budget {
        None => None
        Some((ledger, _, _)) => {
          let pool = ledger
            .pool(
              if control_packet(packet) {
                ControlWork
              } else {
                Routing
              },
              self.runtime.config
              .broker_config()
              .resources()
              .get(
                if control_packet(packet) {
                  "control_reserve_bytes"
                } else {
                  "max_routing_scratch_bytes"
                },
              ),
            )
            .unwrap()
          match pool.reserve(bound * 2L) {
            Ok(t) => Some(t)
            Err(_) => {
              release_frame_reservation(ticket)
              return Err(SlowConsumer)
            }
          }
        }
      }
      (ticket, temporary)
    }
  }
  defer release_optional(temporary)
  let frame = match @protocol.encode_packet(packet) {
    Ok(frame) => frame
    Err(_) => {
      release_frame_reservation(ticket)
      return Err(EncodeFailure)
    }
  }
  if sink.enqueue_frame(frame, ticket, close, authorization?) {
    Ok(())
  } else {
    Err(SlowConsumer)
  }
}

///|
async fn RouterDriver::run_budgeted(
  self : RouterDriver,
  bus : EventBus,
) -> Unit {
  for ;; {
    let event = match bus.next() {
      Some(e) => e
      None => return
    }
    self.handle(event)
    bus.completed(event)
    bus.needs_promotion = self.runtime.broker_state().pending_qos1_count() > 0
  }
}

///|
fn RouterDriver::snapshot_deferred(
  self : RouterDriver,
  state : SnapshotDriverState,
) -> Unit {
  if state.budget_deferred < 9223372036854775807L {
    state.budget_deferred += 1L
    self.runtime.metrics.snapshot_budget_deferred = state.budget_deferred
  }
  let now = @budget.monotonic_ms()
  if now - state.last_budget_log_ms >= 10000L {
    state.last_budget_log_ms = now
    self.runtime.logger.log(
      @observability.LogRecord::new(
        @async.now(),
        @observability.Warn,
        "snapshot_budget_deferred",
        reason="snapshot_work_budget",
        message="snapshot remains dirty; increase resource headroom or reduce retained/session backlog",
      ),
    )
  }
}
