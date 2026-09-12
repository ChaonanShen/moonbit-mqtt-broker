///|
pub(all) enum OutboundCommand {
  WriteFrame(Bytes)
  WriteFrameThenClose(Bytes, CloseReason)
} derive(Eq, Debug)

///|
priv struct FrameReservation {
  ticket : @budget.Ticket
  pool : @budget.Pool
}

///|
priv struct OwnedFrame {
  frame : Bytes
  ticket : @budget.Ticket
}

///|
pub struct TransportSink {
  priv mut budget : (@budget.Ledger, @budget.Pool, @budget.Pool)?
  priv mut owned : Array[OwnedFrame]
  outbound : @async.Queue[OutboundCommand]
  close_signal : @async.Queue[CloseReason]
}

///|
pub fn TransportSink::new(max_outbound : Int) -> TransportSink {
  {
    budget: None,
    owned: [],
    outbound: @async.Queue(kind=Blocking(max_outbound)),
    close_signal: @async.Queue(kind=Blocking(1)),
  }
}

///|
pub fn TransportSink::outbound(
  self : TransportSink,
) -> @async.Queue[OutboundCommand] {
  self.outbound
}

///|
pub fn TransportSink::close_signal(
  self : TransportSink,
) -> @async.Queue[CloseReason] {
  self.close_signal
}

///|
pub fn TransportSink::close(self : TransportSink) -> Unit {
  for frame in self.owned {
    frame.ticket.release().unwrap()
  }
  self.owned = []
  self.outbound.close(clear=true)
  self.close_signal.close(clear=true)
}

///|
fn TransportSink::set_budget(
  self : TransportSink,
  ledger : @budget.Ledger,
  pool : @budget.Pool,
  control : @budget.Pool,
) -> Unit {
  self.budget = Some((ledger, pool, control))
}

///|
fn TransportSink::reserve_frame(
  self : TransportSink,
  bytes : Int64,
  control : Bool,
) -> Result[FrameReservation?, @budget.BudgetError] {
  match self.budget {
    None => Ok(None)
    Some((ledger, data_pool, control_pool)) => {
      let pool = if control { control_pool } else { data_pool }
      ledger
      .reserve([pool.allocation(bytes)])
      .map(ticket => Some({ ticket, pool }))
    }
  }
}

///|
fn release_frame_reservation(reservation : FrameReservation?) -> Unit {
  if reservation is Some(r) {
    r.ticket.release().unwrap()
  }
}

///|
fn TransportSink::enqueue_frame(
  self : TransportSink,
  frame : Bytes,
  reservation : FrameReservation?,
  close : CloseReason?,
) -> Bool {
  let command = match close {
    None => WriteFrame(frame)
    Some(reason) => WriteFrameThenClose(frame, reason)
  }
  let accepted = self.outbound.try_put(command) catch { _ => false }
  if reservation is Some(r) {
    if accepted {
      r.ticket.replace([r.pool.allocation(frame.length().to_int64())]).unwrap()
      r.ticket.commit().unwrap()
      self.owned.push({ frame, ticket: r.ticket })
    } else {
      r.ticket.release().unwrap()
    }
  }
  accepted
}

///|
fn TransportSink::take_frame_ticket(
  self : TransportSink,
  frame : Bytes,
) -> @budget.Ticket? {
  for index in 0..<self.owned.length() {
    if physical_equal(self.owned[index].frame, frame) {
      let ticket = self.owned[index].ticket
      let remaining : Array[OwnedFrame] = []
      for i in 0..<self.owned.length() {
        if i != index {
          remaining.push(self.owned[i])
        }
      }
      self.owned = remaining
      return Some(ticket)
    }
  }
  None
}
