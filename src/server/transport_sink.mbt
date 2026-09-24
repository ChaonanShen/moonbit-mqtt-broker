///|
pub(all) enum OutboundCommand {
  WriteFrame(Bytes)
  WriteFrameThenClose(Bytes, CloseReason)
  WriteWsWake
  WriteWsClose(Bytes)
} derive(Eq, Debug)

///|
pub(all) struct OutboundAuthorization {
  connection_id : ConnectionId
  client_id : @session.ClientId
  session_incarnation : Int64?
  topic : @topic.TopicName
}

///|
fn OutboundAuthorization::cost(self : OutboundAuthorization) -> Int64 {
  128L + @budget.utf8_bytes(self.topic.value())
}

///|
priv struct FrameReservation {
  ticket : @budget.Ticket
  pool : @budget.Pool
}

///|
priv struct OwnedFrame {
  frame : Bytes
  ticket : @budget.Ticket?
  authorization : OutboundAuthorization?
}

///|
pub struct TransportSink {
  priv mut handshake : (FrameReservation, @budget.Ticket)?
  priv mut budget : (@budget.Ledger, @budget.Pool, @budget.Pool)?
  priv mut owned : Array[OwnedFrame]
  priv mut writer_gate : ((OutboundAuthorization) -> Bool)?
  priv mut handshake_resolved : Bool
  priv handshake_gate : @async.Queue[Bool]
  outbound : @async.Queue[OutboundCommand]
  close_signal : @async.Queue[CloseReason]
  ws_close_ack : @async.Queue[Unit]
  ws_control : @async.Queue[Bytes]
  mut ws_closing : Bool
  mut ws_wake_pending : Bool
}

///|
pub fn TransportSink::new(max_outbound : Int) -> TransportSink {
  {
    handshake: None,
    budget: None,
    owned: [],
    writer_gate: None,
    handshake_resolved: false,
    handshake_gate: @async.Queue(kind=Blocking(1)),
    outbound: @async.Queue(kind=Blocking(max_outbound)),
    close_signal: @async.Queue(kind=Blocking(1)),
    ws_close_ack: @async.Queue(kind=Blocking(1)),
    ws_control: @async.Queue(kind=Blocking(4)),
    ws_closing: false,
    ws_wake_pending: false,
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
fn TransportSink::try_handshake(self : TransportSink) -> Bool? {
  self.handshake_gate.try_get() catch {
    _ => Some(false)
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
    release_optional(frame.ticket)
  }
  self.owned = []
  self.writer_gate = None
  if !self.handshake_resolved {
    self.resolve_handshake(false)
  }
  self.handshake_gate.close(clear=true)
  self.outbound.close(clear=true)
  self.close_signal.close(clear=true)
  self.ws_close_ack.close(clear=true)
  self.ws_control.close(clear=true)
}

///|
fn TransportSink::set_writer_gate(
  self : TransportSink,
  gate : (OutboundAuthorization) -> Bool,
) -> Unit {
  self.writer_gate = Some(gate)
}

///|
fn TransportSink::authorize(
  self : TransportSink,
  authorization : OutboundAuthorization,
) -> Bool {
  match self.writer_gate {
    Some(gate) => gate(authorization)
    None => false
  }
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
  authorization? : OutboundAuthorization,
) -> Bool {
  let command = match close {
    None => WriteFrame(frame)
    Some(reason) => WriteFrameThenClose(frame, reason)
  }
  let accepted = self.outbound.try_put(command) catch { _ => false }
  let ticket = match reservation {
    Some(r) =>
      if accepted {
        let cost = frame.length().to_int64() +
          authorization.map(value => value.cost()).unwrap_or(0L)
        r.ticket.replace([r.pool.allocation(cost)]).unwrap()
        r.ticket.commit().unwrap()
        Some(r.ticket)
      } else {
        r.ticket.release().unwrap()
        None
      }
    None => None
  }
  if accepted {
    self.owned.push({ frame, ticket, authorization })
  }
  accepted
}

///|
fn TransportSink::enqueue_ws_control(
  self : TransportSink,
  frame : Bytes,
) -> Bool {
  let reservation = match self.reserve_frame(frame.length().to_int64(), true) {
    Ok(value) => value
    Err(_) => return false
  }
  let accepted = self.ws_control.try_put(frame) catch { _ => false }
  if accepted && !self.ws_wake_pending {
    self.ws_wake_pending = self.outbound.try_put(WriteWsWake) catch {
      _ => false
    }
  }
  if reservation is Some(r) {
    if accepted {
      r.ticket.commit().unwrap()
      self.owned.push({ frame, ticket: Some(r.ticket), authorization: None })
    } else {
      r.ticket.release().unwrap()
    }
  }
  accepted
}

///|
fn TransportSink::enqueue_ws_close(self : TransportSink, frame : Bytes) -> Bool {
  let reservation = match self.reserve_frame(frame.length().to_int64(), true) {
    Ok(value) => value
    Err(_) => return false
  }
  let accepted = self.outbound.try_put(WriteWsClose(frame)) catch { _ => false }
  if accepted {
    self.ws_closing = true
  }
  if reservation is Some(r) {
    if accepted {
      r.ticket.commit().unwrap()
      self.owned.push({ frame, ticket: Some(r.ticket), authorization: None })
    } else {
      r.ticket.release().unwrap()
    }
  }
  accepted
}

///|
async fn TransportSink::wait_ws_close(self : TransportSink) -> Unit {
  ignore(@async.with_timeout_opt(1000, () => self.ws_close_ack.get())) catch {
    _ => ()
  }
}

///|
fn TransportSink::take_ws_control(self : TransportSink) -> Bytes? {
  self.ws_control.try_get() catch {
    _ => None
  }
}

///|
fn TransportSink::take_owned_frame(
  self : TransportSink,
  frame : Bytes,
) -> (@budget.Ticket?, OutboundAuthorization?) {
  for index in 0..<self.owned.length() {
    if physical_equal(self.owned[index].frame, frame) {
      let owned = self.owned[index]
      let remaining : Array[OwnedFrame] = []
      for i in 0..<self.owned.length() {
        if i != index {
          remaining.push(self.owned[i])
        }
      }
      self.owned = remaining
      return (owned.ticket, owned.authorization)
    }
  }
  (None, None)
}

///|
fn TransportSink::take_frame_ticket(
  self : TransportSink,
  frame : Bytes,
) -> @budget.Ticket? {
  self.take_owned_frame(frame).0
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
