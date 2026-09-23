///|
pub(all) struct ManagementCommandTicket {
  slot : Int
  generation : Int64
} derive(Eq, Debug)

///|
pub(all) enum ManagementCommandEvent {
  SubmitCommand(
    ManagementCommandTicket,
    @management.CommandSpec,
    @management.AdminPrincipal
  )
  RunCommand(String, @management.CommandSpec)
}

///|
pub(all) struct ManagementCommandReply {
  status : @http_transport.HttpStatus
  body : Bytes
  location : String?
}

///|
priv struct ManagementCommandSlot {
  mut generation : Int64
  mut occupied : Bool
  mut ready : Bool
  mut reply : ManagementCommandReply?
  signal : @async.Queue[Unit]
}

///|
pub struct ManagementCommandMailbox {
  queue : @async.Queue[ManagementCommandEvent]
  priv slots : Array[ManagementCommandSlot]
  mut wake : @async.Queue[Unit]?
  mut closed : Bool
}

///|
pub fn ManagementCommandMailbox::new(
  capacity : Int,
) -> ManagementCommandMailbox {
  let slots : Array[ManagementCommandSlot] = []
  for _ in 0..<capacity {
    slots.push({
      generation: 0L,
      occupied: false,
      ready: false,
      reply: None,
      signal: @async.Queue(kind=Blocking(1)),
    })
  }
  {
    queue: @async.Queue(kind=Blocking(capacity)),
    slots,
    wake: None,
    closed: false,
  }
}

///|
fn ManagementCommandMailbox::set_wake(
  self : ManagementCommandMailbox,
  wake : @async.Queue[Unit],
) -> Unit {
  self.wake = Some(wake)
}

///|
fn ManagementCommandMailbox::notify(self : ManagementCommandMailbox) -> Unit {
  if self.wake is Some(wake) {
    ignore(wake.try_put(())) catch {
      _ => ()
    }
  }
}

///|
pub fn ManagementCommandMailbox::submit(
  self : ManagementCommandMailbox,
  spec : @management.CommandSpec,
  actor : @management.AdminPrincipal,
) -> ManagementCommandTicket? {
  if self.closed {
    return None
  }
  for slot in 0..<self.slots.length() {
    let state = self.slots[slot]
    if !state.occupied && state.generation < 9223372036854775807L {
      state.generation += 1L
      state.occupied = true
      state.ready = false
      state.reply = None
      ignore(state.signal.try_get()) catch {
        _ => ()
      }
      let ticket : ManagementCommandTicket = {
        slot,
        generation: state.generation,
      }
      if !(self.queue.try_put(SubmitCommand(ticket, spec, actor)) catch {
          _ => false
        }) {
        state.occupied = false
        return None
      }
      self.notify()
      return Some(ticket)
    }
  }
  None
}

///|
fn ManagementCommandMailbox::schedule_run(
  self : ManagementCommandMailbox,
  operation_id : String,
  spec : @management.CommandSpec,
) -> Bool {
  if self.closed {
    return false
  }
  let accepted = self.queue.try_put(RunCommand(operation_id, spec)) catch {
    _ => false
  }
  if accepted {
    self.notify()
  }
  accepted
}

///|
fn ManagementCommandMailbox::take(
  self : ManagementCommandMailbox,
) -> ManagementCommandEvent? {
  self.queue.try_get() catch {
    _ => None
  }
}

///|
fn ManagementCommandMailbox::valid(
  self : ManagementCommandMailbox,
  ticket : ManagementCommandTicket,
) -> Bool {
  ticket.slot >= 0 &&
  ticket.slot < self.slots.length() &&
  self.slots[ticket.slot].occupied &&
  self.slots[ticket.slot].generation == ticket.generation
}

///|
fn ManagementCommandMailbox::produce(
  self : ManagementCommandMailbox,
  ticket : ManagementCommandTicket,
  reply : ManagementCommandReply,
) -> Unit {
  if !self.valid(ticket) {
    return
  }
  let state = self.slots[ticket.slot]
  state.reply = Some(reply)
  state.ready = true
  ignore(state.signal.try_put(())) catch {
    _ => ()
  }
}

///|
pub async fn ManagementCommandMailbox::wait(
  self : ManagementCommandMailbox,
  ticket : ManagementCommandTicket,
) -> ManagementCommandReply? {
  if !self.valid(ticket) {
    return None
  }
  let state = self.slots[ticket.slot]
  if !state.ready {
    state.signal.get() catch {
      _ => return None
    }
  }
  if self.valid(ticket) && state.ready {
    state.reply
  } else {
    None
  }
}

///|
pub fn ManagementCommandMailbox::release(
  self : ManagementCommandMailbox,
  ticket : ManagementCommandTicket,
) -> Unit {
  if self.valid(ticket) {
    let state = self.slots[ticket.slot]
    state.occupied = false
    state.ready = false
    state.reply = None
  }
}

///|
/// Return accepted-but-unstarted Run IDs to the driver for terminal shutdown
/// accounting. Queued HTTP submissions receive a bounded unavailable reply.
fn ManagementCommandMailbox::close(
  self : ManagementCommandMailbox,
) -> Array[String] {
  let queued : Array[String] = []
  if self.closed {
    return queued
  }
  self.closed = true
  for ;; {
    let event = self.queue.try_get() catch { _ => None }
    match event {
      Some(SubmitCommand(ticket, _, _)) =>
        self.produce(ticket, {
          status: @http_transport.ServiceUnavailable,
          body: b"{\"error\":{\"code\":\"unavailable\"}}",
          location: None,
        })
      Some(RunCommand(operation_id, _)) => queued.push(operation_id)
      None => break
    }
  }
  self.queue.close(clear=true)
  queued
}
