///|
pub struct RouterDriver {
  runtime : BrokerRuntime
  sinks : Map[ConnectionId, TransportSink]
  priv snapshot : SnapshotDriverState?
  priv auth_executor : @security.AuthExecutor?
  priv mut auth_infrastructure : @budget.Ticket?
  priv auth_cancels : Map[Int64, Bool]
  priv auth_reaps : Map[Int64, Bool]
  priv mut last_progress_monotonic_ms : Int64
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
    snapshot,
    auth_executor,
    auth_infrastructure,
    auth_cancels: Map([]),
    auth_reaps: Map([]),
    last_progress_monotonic_ms: @budget.monotonic_ms(),
  }
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
        self.dispatch(
          self.runtime.apply(
            AuthenticationCompleted({
              request_id,
              outcome: @security.AuthCompletionOutcome::AuthInternalFailure,
              completed_at_ms: @async.now(),
            }),
          ),
        )
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
      ControlRetryLater => ()
      _ => self.auth_reaps.remove(request_id)
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
        self.dispatch(
          self.runtime.apply(
            AuthenticationCompleted({
              request_id: completed.task_id,
              outcome: completed.outcome,
              completed_at_ms: @async.now(),
            }),
          ),
        )
        match executor.reap(completed.task_id) {
          ControlDone | ControlInvalid => ()
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
          match self.encode_and_queue(sink, send.packet, None) {
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
          )
          if send.packet is Connack(_) {
            sink.resolve_handshake(false)
          }
          if result is Err(reason) {
            sink.try_close(reason)
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
              CancelUnknown =>
                worklist.append(
                  self.runtime.apply(
                    AuthenticationCompleted({
                      request_id: cancel.request_id,
                      outcome: @security.AuthCompletionOutcome::AuthInternalFailure,
                      completed_at_ms: @async.now(),
                    }),
                  ),
                )
              _ => ()
            }
        }
    }
  }
}

///|
pub fn RouterDriver::handle(self : RouterDriver, event : DriverEvent) -> Unit {
  self.runtime.broker_state().begin_action_scope()
  defer {
    self.last_progress_monotonic_ms = @budget.monotonic_ms()
  }
  defer self.runtime.broker_state().end_action_scope()
  match event {
    Accounted(event, ticket) => {
      defer ticket.release().unwrap()
      self.handle_runtime_event(event)
    }
    RegisterTransport(register) => {
      if self.sinks.get(register.connection_id) is Some(_) {
        return
      }
      self.sinks.set(register.connection_id, register.sink)
      self.dispatch(
        self.runtime.apply(
          TransportOpened({
            connection_id: register.connection_id,
            accepted_at_ms: register.accepted_at_ms,
          }),
        ),
      )
    }
    Runtime(event) => self.handle_runtime_event(event)
    UnregisterTransport(connection_id) => self.sinks.remove(connection_id)
  }
  self.poll_authentication()
  ignore(self.poll_snapshot(@async.now()))
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
  if event is PacketReceived(packet) {
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
fn RouterDriver::encode_and_queue(
  self : RouterDriver,
  sink : TransportSink,
  packet : @protocol.Packet,
  close : CloseReason?,
) -> Result[Unit, CloseReason] {
  let bound = wire_cost_bound(packet)
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
      let ticket = match sink.reserve_frame(bound, control_packet(packet)) {
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
  if sink.enqueue_frame(frame, ticket, close) {
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
