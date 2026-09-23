///|
pub(all) struct ManagementQueryTicket {
  slot : Int
  generation : Int64
} derive(Eq, Debug)

///|
pub(all) struct ManagementQueryEvent {
  ticket : ManagementQueryTicket
  spec : @management.QuerySpec
}

///|
pub(all) struct ManagementQueryReply {
  status : @http_transport.HttpStatus
  body : Bytes
}

///|
priv struct ManagementQuerySlot {
  mut generation : Int64
  mut occupied : Bool
  mut abandoned : Bool
  mut ready : Bool
  mut reply : ManagementQueryReply?
  signal : @async.Queue[Unit]
}

///|
/// Bounded slot/generation mailbox shared by HTTP producers and the single
/// broker writer. Producers never await queue capacity.
pub struct ManagementQueryMailbox {
  queue : @async.Queue[ManagementQueryEvent]
  priv slots : Array[ManagementQuerySlot]
  mut wake : @async.Queue[Unit]?
  mut closed : Bool
}

///|
pub fn ManagementQueryMailbox::new(capacity : Int) -> ManagementQueryMailbox {
  let slots : Array[ManagementQuerySlot] = []
  for _ in 0..<capacity {
    slots.push({
      generation: 0L,
      occupied: false,
      abandoned: false,
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
fn ManagementQueryMailbox::set_wake(
  self : ManagementQueryMailbox,
  wake : @async.Queue[Unit],
) -> Unit {
  self.wake = Some(wake)
}

///|
pub fn ManagementQueryMailbox::submit(
  self : ManagementQueryMailbox,
  spec : @management.QuerySpec,
) -> ManagementQueryTicket? {
  if self.closed {
    return None
  }
  for slot in 0..<self.slots.length() {
    let state = self.slots[slot]
    if !state.occupied && state.generation < 9223372036854775807L {
      state.generation += 1L
      state.occupied = true
      state.abandoned = false
      state.ready = false
      state.reply = None
      ignore(state.signal.try_get()) catch {
        _ => ()
      }
      let ticket : ManagementQueryTicket = {
        slot,
        generation: state.generation,
      }
      let queued = self.queue.try_put({ ticket, spec }) catch { _ => false }
      if !queued {
        state.occupied = false
        return None
      }
      if self.wake is Some(wake) {
        ignore(wake.try_put(())) catch {
          _ => ()
        }
      }
      return Some(ticket)
    }
  }
  None
}

///|
fn ManagementQueryMailbox::take(
  self : ManagementQueryMailbox,
) -> ManagementQueryEvent? {
  self.queue.try_get() catch {
    _ => None
  }
}

///|
fn ManagementQueryMailbox::valid(
  self : ManagementQueryMailbox,
  ticket : ManagementQueryTicket,
) -> Bool {
  ticket.slot >= 0 &&
  ticket.slot < self.slots.length() &&
  self.slots[ticket.slot].occupied &&
  self.slots[ticket.slot].generation == ticket.generation
}

///|
fn ManagementQueryMailbox::produce(
  self : ManagementQueryMailbox,
  ticket : ManagementQueryTicket,
  reply : ManagementQueryReply,
) -> Unit {
  if !self.valid(ticket) {
    return
  }
  let state = self.slots[ticket.slot]
  if state.abandoned {
    state.occupied = false
    state.reply = None
  } else {
    state.reply = Some(reply)
    state.ready = true
    ignore(state.signal.try_put(())) catch {
      _ => ()
    }
  }
}

///|
pub async fn ManagementQueryMailbox::wait(
  self : ManagementQueryMailbox,
  ticket : ManagementQueryTicket,
) -> ManagementQueryReply? {
  if !self.valid(ticket) {
    return None
  }
  let state = self.slots[ticket.slot]
  if !state.ready {
    state.signal.get() catch {
      _ => return None
    }
  }
  if !self.valid(ticket) || !state.ready {
    return None
  }
  state.reply
}

///|
pub fn ManagementQueryMailbox::release(
  self : ManagementQueryMailbox,
  ticket : ManagementQueryTicket,
) -> Unit {
  if !self.valid(ticket) {
    return
  }
  let state = self.slots[ticket.slot]
  state.abandoned = true
  state.reply = None
  state.ready = false
  state.occupied = false
}

///|
pub fn ManagementQueryMailbox::active_count(
  self : ManagementQueryMailbox,
) -> Int {
  let mut active = 0
  for state in self.slots {
    if state.occupied {
      active += 1
    }
  }
  active
}

///|
fn ManagementQueryMailbox::close(self : ManagementQueryMailbox) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for ;; {
    let event = self.queue.try_get() catch { _ => None }
    match event {
      Some(event) =>
        self.produce(event.ticket, {
          status: @http_transport.ServiceUnavailable,
          body: b"{\"error\":{\"code\":\"unavailable\"}}",
        })
      None => break
    }
  }
  self.queue.close(clear=true)
}
