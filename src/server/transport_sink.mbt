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
  priv mut handshake : (FrameReservation, @budget.Ticket)?
  priv mut budget : (@budget.Ledger, @budget.Pool, @budget.Pool)?
  priv mut owned : Array[OwnedFrame]
  priv mut handshake_resolved : Bool
  priv handshake_gate : @async.Queue[Bool]
  outbound : @async.Queue[OutboundCommand]
  close_signal : @async.Queue[CloseReason]
}

///|
pub fn TransportSink::new(max_outbound : Int) -> TransportSink {
  {
    handshake: None,
    budget: None,
    owned: [],
    handshake_resolved: false,
    handshake_gate: @async.Queue(kind=Blocking(1)),
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
pub async fn TransportSink::wait_handshake(self : TransportSink) -> Bool {
  self.handshake_gate.get() catch {
    _ => false
  }
}

///|
fn TransportSink::resolve_handshake(
  self : TransportSink,
  accepted : Bool,
) -> Unit {
  if self.handshake_resolved {
    return
  }
  self.handshake_resolved = true
  ignore(self.handshake_gate.try_put(accepted)) catch {
    _ => ()
  }
}

///|
pub fn TransportSink::close_signal(
  self : TransportSink,
) -> @async.Queue[CloseReason] {
  self.close_signal
}

///|
pub fn TransportSink::close(self : TransportSink) -> Unit {
  if self.handshake is Some((frame, scratch)) {
    frame.ticket.release().unwrap()
    scratch.release().unwrap()
    self.handshake = None
  }
  for frame in self.owned {
    frame.ticket.release().unwrap()
  }
  self.owned = []
  if !self.handshake_resolved {
    self.resolve_handshake(false)
  }
  self.handshake_gate.close(clear=true)
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

///|
/// Reserve both the first response and encoding scratch before session takeover.
fn TransportSink::prepare_handshake(
  self : TransportSink,
  control_limit : Int64,
) -> Bool {
  if self.handshake is Some(_) {
    return false
  }
  match self.budget {
    None => true
    Some((ledger, _, control)) => {
      let scratch_pool = ledger.pool(ControlWork, control_limit).unwrap()
      let frame = match control.reserve(4L) {
        Ok(t) => t
        Err(_) => return false
      }
      let scratch = match scratch_pool.reserve(8L) {
        Ok(t) => t
        Err(_) => {
          frame.release().unwrap()
          return false
        }
      }
      self.handshake = Some(({ ticket: frame, pool: control }, scratch))
      true
    }
  }
}
