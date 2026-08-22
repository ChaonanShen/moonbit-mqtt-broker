///|
pub struct RouterDriver {
  runtime : BrokerRuntime
  sinks : Map[ConnectionId, TransportSink]
}

///|
pub fn RouterDriver::new(runtime : BrokerRuntime) -> RouterDriver {
  { runtime, sinks: Map([]) }
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
fn TransportSink::try_outbound(
  self : TransportSink,
  command : OutboundCommand,
) -> Bool {
  self.outbound.try_put(command) catch {
    _ => false
  }
}

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
        match self.sinks.get(send.connection_id) {
          None => ()
          Some(sink) =>
            match @protocol.encode_packet(send.packet) {
              Err(_) =>
                worklist.append(
                  self.transport_failed(send.connection_id, EncodeFailure),
                )
              Ok(frame) =>
                if !sink.try_outbound(WriteFrame(frame)) {
                  worklist.append(
                    self.transport_failed(send.connection_id, SlowConsumer),
                  )
                }
            }
        }
      SendPacketThenClose(send) =>
        match self.sinks.get(send.connection_id) {
          None => ()
          Some(sink) =>
            match @protocol.encode_packet(send.packet) {
              Err(_) => {
                sink.try_close(EncodeFailure)
                worklist.append(
                  self.transport_failed(send.connection_id, EncodeFailure),
                )
              }
              Ok(frame) =>
                if !sink.try_outbound(WriteFrameThenClose(frame, send.reason)) {
                  sink.try_close(SlowConsumer)
                  worklist.append(
                    self.transport_failed(send.connection_id, SlowConsumer),
                  )
                }
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
  match event {
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
    Runtime(event) => self.dispatch(self.runtime.apply(event))
    UnregisterTransport(connection_id) => self.sinks.remove(connection_id)
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
