///|
suberror ResourceStartupFailure {
  ResourceStartupFailure(String)
} derive(Debug)

///|
priv struct ConnectionBudget {
  receive : @budget.Pool
  events : @budget.Pool
  control_events : @budget.Pool
  metadata : @budget.Ticket
}

///|
priv struct ControlSlot {
  registration : RegisterTransportEvent
  ready : @async.Queue[Unit]
  budget : ConnectionBudget
  mut registered : Bool
  mut pending_packets : Int
  mut terminal : TransportClosedEvent?
  mut terminal_delivered : Bool
}

///|
priv struct EventBus {
  admission : AdmissionState
  config : ServerConfig
  ledger : @budget.Ledger
  data : @async.Queue[DriverEvent]
  wake : @async.Queue[Unit]
  slots : Map[ConnectionId, ControlSlot]
  infrastructure : @budget.Ticket
  mut tick : RuntimeEvent?
  mut metrics : RuntimeEvent?
  mut deferred_data : DriverEvent?
  mut control_batch : Int
  mut closed : Bool
}

///|
fn EventBus::new(
  config : ServerConfig,
  ledger : @budget.Ledger,
  data : @async.Queue[DriverEvent],
) -> Result[EventBus, @budget.BudgetError] {
  let limits = config.broker_config().resources()
  let control = ledger
    .pool(ControlEvent, limits.get("control_reserve_bytes"))
    .unwrap()
  let fixed = ledger
    .pool(Infrastructure, limits.get("max_managed_bytes_total"))
    .unwrap()
  let infrastructure = match
    ledger.reserve([
      control.allocation(config.max_connections().to_int64() * 512L + 256L),
      fixed.allocation(config.max_runtime_events().to_int64() * 64L + 16384L),
    ]) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  infrastructure.commit().unwrap()
  Ok({
    config,
    admission: AdmissionState::new(config, ledger),
    ledger,
    data,
    wake: @async.Queue(kind=Blocking(1)),
    slots: Map([]),
    infrastructure,
    tick: None,
    metrics: None,
    deferred_data: None,
    control_batch: 0,
    closed: false,
  })
}

///|
fn EventBus::signal(self : EventBus) -> Unit {
  ignore(self.wake.try_put(())) catch {
    _ => ()
  }
}

///|
fn EventBus::register(
  self : EventBus,
  id : ConnectionId,
  sink : TransportSink,
) -> Result[ConnectionBudget, @budget.BudgetError] {
  if self.closed ||
    self.slots.contains(id) ||
    self.slots.length() >= self.config.max_connections() {
    return Err(@budget.BudgetError::InvalidConfiguration)
  }
  let limits = self.config.broker_config().resources()
  let receive = self.ledger
    .pool(Receive, limits.get("max_receive_bytes_total"))
    .unwrap()
    .with_account(
      self.ledger
      .account(
        Connection,
        self.config.max_receive_buffer_size().to_int64() * 4L + 8192L,
      )
      .unwrap(),
    )
    .unwrap()
  let event_cap = self.ledger
    .account(
      Connection,
      limits.get("max_runtime_bytes_per_connection"),
      label="runtime_connection",
    )
    .unwrap()
  let global_events = self.ledger
    .pool(RuntimeEvent, limits.get("max_runtime_bytes_total"))
    .unwrap()
  let events = global_events.with_account(event_cap).unwrap()
  let control_events = self.ledger
    .pool(ControlRuntime, limits.get("control_reserve_bytes"))
    .unwrap()
    .with_account(global_events.category_account())
    .unwrap()
    .with_account(event_cap)
    .unwrap()
  let outbound_cap = self.ledger
    .account(
      Connection,
      limits.get("max_outbound_bytes_per_connection"),
      label="outbound_connection",
    )
    .unwrap()
  let global_outbound = self.ledger
    .pool(Outbound, limits.get("max_outbound_bytes_total"))
    .unwrap()
  let outbound = global_outbound.with_account(outbound_cap).unwrap()
  let control_outbound = self.ledger
    .pool(ControlFrame, limits.get("control_reserve_bytes"))
    .unwrap()
    .with_account(global_outbound.category_account())
    .unwrap()
    .with_account(outbound_cap)
    .unwrap()
  let metadata_pool = self.ledger
    .pool(ConnectionMetadata, limits.get("max_connection_metadata_bytes_total"))
    .unwrap()
  let metadata = match self.ledger.reserve([metadata_pool.allocation(512L)]) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  metadata.commit().unwrap()
  let budget = ConnectionBudget::{ receive, events, control_events, metadata }
  sink.set_budget(self.ledger, outbound, control_outbound)
  self.slots.set(id, {
    ready: @async.Queue(kind=Blocking(1)),
    registration: { connection_id: id, sink, accepted_at_ms: @async.now() },
    budget,
    registered: false,
    pending_packets: 0,
    terminal: None,
    terminal_delivered: false,
  })
  self.admission.registered(id)
  self.signal()
  Ok(budget)
}

///|
/// Only a readiness token is awaited, never Queue.put(packet). The waiting
/// reader retains its accounted packet; cancellation leaves no packet payload
/// in the dependency's cancelled-writer list.
async fn EventBus::post_packet(
  self : EventBus,
  event : PacketReceivedEvent,
  ticket : @budget.Ticket,
) -> Bool {
  let slot = match self.slots.get(event.connection_id) {
    Some(s) => s
    None => return false
  }
  for ;; {
    if self.closed || slot.terminal is Some(_) {
      return false
    }
    if slot.pending_packets < self.config.max_runtime_events() &&
      slot.pending_packets.to_int64() <
      self.config
      .broker_config()
      .resources()
      .get("max_runtime_events_per_connection") {
      let accepted = self.data.try_put(
        Accounted(RuntimeEvent::PacketReceived(event), ticket),
      ) catch {
        _ => false
      }
      if accepted {
        slot.pending_packets += 1
        self.signal()
        return true
      }
    }
    slot.ready.get() catch {
      _ => return false
    }
  }
}

///|
fn EventBus::signal_space(self : EventBus) -> Unit {
  for _, slot in self.slots {
    ignore(slot.ready.try_put(())) catch {
      _ => ()
    }
  }
}

///|
fn EventBus::terminal(self : EventBus, event : TransportClosedEvent) -> Unit {
  if self.slots.get(event.connection_id) is Some(slot) {
    if slot.terminal is None {
      slot.terminal = Some(event)
    }
    self.signal()
  }
}

///|
fn EventBus::post_tick(self : EventBus, event : RuntimeEvent) -> Unit {
  match event {
    CheckDeadlines(_) => self.tick = Some(event)
    _ => self.metrics = Some(event)
  }
  self.signal()
}

///|
fn EventBus::take_control(self : EventBus) -> DriverEvent? {
  if self.tick is Some(tick) {
    self.tick = None
    return Some(Runtime(tick))
  }
  for id, slot in self.slots {
    if !slot.registered {
      slot.registered = true
      return Some(RegisterTransport(slot.registration))
    }
    // An asynchronous terminal cannot overtake packets already admitted from
    // the same connection. Rejected/unfinished reads were never enqueued.
    if slot.pending_packets == 0 && slot.terminal is Some(terminal) {
      if !slot.terminal_delivered {
        slot.terminal_delivered = true
        return Some(Runtime(TransportClosed(terminal)))
      }
      slot.budget.metadata.release().unwrap()
      self.admission.forget(id)
      slot.ready.close(clear=true)
      self.slots.remove(id)
      return Some(UnregisterTransport(id))
    }
  }
  if self.metrics is Some(metrics) {
    self.metrics = None
    return Some(Runtime(metrics))
  }
  None
}

///|
async fn EventBus::next(self : EventBus) -> DriverEvent? {
  for ;; {
    if self.closed {
      return None
    }
    if self.control_batch < 8 {
      if self.take_control() is Some(event) {
        self.control_batch += 1
        return Some(event)
      }
    }
    let data = match self.deferred_data {
      Some(event) => {
        self.deferred_data = None
        Some(event)
      }
      None => self.data.try_get() catch { _ => return None }
    }
    if data is Some(event) {
      self.signal_space()
      self.control_batch = 0
      if event is Accounted(PacketReceived(packet), _) {
        if self.slots.get(packet.connection_id) is Some(slot) &&
          !slot.registered {
          slot.registered = true
          self.deferred_data = Some(event)
          return Some(RegisterTransport(slot.registration))
        }
      }
      return Some(event)
    }
    self.control_batch = 0
    if self.take_control() is Some(event) {
      return Some(event)
    }
    self.wake.get() catch {
      _ => return None
    }
  }
}

///|
fn EventBus::completed(self : EventBus, event : DriverEvent) -> Unit {
  if event is Accounted(PacketReceived(packet), _) {
    if self.slots.get(packet.connection_id) is Some(slot) {
      slot.pending_packets -= 1
      ignore(slot.ready.try_put(())) catch {
        _ => ()
      }
    }
  }
}

///|
fn EventBus::close(self : EventBus) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.deferred_data is Some(Accounted(_, ticket)) {
    ticket.release().unwrap()
  }
  self.deferred_data = None
  for ;; {
    let event = self.data.try_get() catch { _ => None }
    match event {
      Some(Accounted(_, ticket)) => ticket.release().unwrap()
      Some(_) => ()
      None => break
    }
  }
  self.data.close(clear=true)
  self.wake.close(clear=true)
  for _, slot in self.slots {
    slot.ready.close(clear=true)
    slot.registration.sink.close()
    slot.budget.metadata.release().unwrap()
  }
  self.slots.clear()
  self.admission.close()
  self.infrastructure.release().unwrap()
}
