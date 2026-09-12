///|
pub struct RouterDriver {
  runtime : BrokerRuntime
  sinks : Map[ConnectionId, TransportSink]
  priv snapshot : SnapshotDriverState?
}

///|
pub struct SnapshotDriverConfig {
  sink : @persistence.SnapshotSink
  debounce_ms : Int64
  max_delay_ms : Int64
}

///|
priv struct SnapshotDriverState {
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
) -> RouterDriver {
  let snapshot = snapshot.map(config => SnapshotDriverState::{
    sink: config.sink,
    schedule: SnapshotSchedule::new(
      runtime.broker_state().snapshot_revision(),
      config.debounce_ms,
      config.max_delay_ms,
    ).unwrap(),
  })
  { runtime, sinks: Map([]), snapshot }
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
  let submitted = state.sink.submit({
    revision,
    snapshot: self.runtime.broker_state().export_snapshot(),
  })
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
          if self.encode_and_queue(sink, send.packet, None) is Err(reason) {
            worklist.append(self.transport_failed(send.connection_id, reason))
          }
        }
      SendPacketThenClose(send) =>
        if self.sinks.get(send.connection_id) is Some(sink) {
          if self.encode_and_queue(sink, send.packet, Some(send.reason))
            is Err(reason) {
            sink.try_close(reason)
            worklist.append(self.transport_failed(send.connection_id, reason))
          }
        }
      CloseTransport(close) =>
        match self.sinks.get(close.connection_id) {
          None => ()
          Some(sink) => sink.try_close(close.reason)
        }
    }
  }
}

///|
pub fn RouterDriver::handle(self : RouterDriver, event : DriverEvent) -> Unit {
  self.runtime.broker_state().begin_action_scope()
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
  }
}
