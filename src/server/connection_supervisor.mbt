///|
fn try_report_terminal(
  terminal : @async.Queue[CloseReason],
  reason : CloseReason,
) -> Unit {
  ignore(terminal.try_put(reason)) catch {
    _ => ()
  }
}

///|
fn next_read_capacity(
  decoder : @framing.FrameDecoder,
  max_receive_buffer_size : Int,
) -> Result[Int, CloseReason] {
  let remaining = max_receive_buffer_size - decoder.buffered_len()
  if remaining <= 0 {
    Err(ProtocolError)
  } else if remaining < 4096 {
    Ok(remaining)
  } else {
    Ok(4096)
  }
}

///|
async fn read_transport(
  connection : ConnectionTransport,
  connection_id : ConnectionId,
  config : ServerConfig,
  events : @async.Queue[DriverEvent],
  bus? : EventBus,
  budget? : ConnectionBudget,
  sink? : TransportSink,
) -> CloseReason {
  let decoder = @framing.FrameDecoder::new(
    config.max_packet_size(),
    config.max_receive_buffer_size(),
  )
  let receive = budget.map(b => b.receive)
  let decoder_ticket = match reserve_optional(receive, 0L) {
    Ok(t) => t
    Err(e) => return e
  }
  defer release_optional(decoder_ticket)
  for ;; {
    let read_capacity = match
      next_read_capacity(decoder, config.max_receive_buffer_size()) {
      Err(reason) => return reason
      Ok(value) => value
    }
    let read_ticket = match
      reserve_optional(receive, read_capacity.to_int64() * 3L) {
      Ok(t) => t
      Err(e) => return e
    }
    defer release_optional(read_ticket)
    let chunk = connection.read_some(max_len=read_capacity) catch {
      _ => return ReadFailure
    }
    let bytes = match chunk {
      None => return PeerEof
      Some(value) => value
    }
    if bus is Some(bus) &&
      !connection.is_websocket() &&
      !bus.admission.admit_ingress(connection_id, bytes.length().to_int64()) {
      return RateLimited
    }
    if resize_optional(read_ticket, receive, bytes.length().to_int64())
      is Err(e) {
      return e
    }
    if resize_optional(
        decoder_ticket,
        receive,
        decoder.buffered_len().to_int64() + bytes.length().to_int64(),
      )
      is Err(e) {
      return e
    }
    match decoder.push(bytes[:]) {
      Err(_) => return ProtocolError
      Ok(_) => ()
    }
    for ;; {
      let extraction = match
        reserve_optional(receive, decoder.buffered_len().to_int64() * 3L) {
        Ok(t) => t
        Err(e) => return e
      }
      defer release_optional(extraction)
      match decoder.next() {
        NeedMoreData => break
        MalformedPacket(_) => return ProtocolError
        CompletePacket(frame) => {
          if resize_optional(
              decoder_ticket,
              receive,
              decoder.buffered_len().to_int64(),
            )
            is Err(e) {
            return e
          }
          let event_pool = budget.map(b => {
            if control_frame(frame) {
              b.control_events
            } else {
              b.events
            }
          })
          let packet_ticket = match
            reserve_optional(event_pool, decode_cost_bound(frame)) {
            Ok(t) => t
            Err(e) => return e
          }
          let mut moved = false
          defer (if !moved { release_optional(packet_ticket) })
          let packet = match @protocol.decode_packet(frame) {
            Err(_) => return ProtocolError
            Ok(value) => value
          }
          if @protocol.validate_direction(
              packet,
              @protocol.PacketDirection::ClientToServer,
            )
            is Err(_) {
            return ProtocolError
          }
          if resize_optional(packet_ticket, event_pool, packet_cost(packet))
            is Err(e) {
            return e
          }
          if bus is Some(bus) &&
            control_packet(packet) &&
            !bus.admission.admit_control(connection_id) {
            return RateLimited
          }
          let event = PacketReceivedEvent::{
            connection_id,
            packet,
            received_at_ms: @async.now(),
          }
          match (bus, packet_ticket) {
            (Some(bus), Some(ticket)) => {
              ticket.commit().unwrap()
              if !bus.post_packet(event, ticket) {
                return ResourceExhausted
              }
              moved = true
            }
            _ =>
              events.put(Runtime(PacketReceived(event))) catch {
                _ => return ServerShutdown
              }
          }
          if packet is Connect(_) && sink is Some(handshake) {
            if connection.is_websocket() {
              let mut resolved : Bool? = None
              while resolved is None {
                resolved = handshake.try_handshake()
                if resolved is None {
                  let remaining = config.max_receive_buffer_size() -
                    decoder.buffered_len()
                  match connection.drain_buffered_controls(remaining) {
                    Some(reason) => return reason
                    None => ()
                  }
                  @async.sleep(5)
                }
              }
              if resolved == Some(false) {
                return ConnectRejected
              }
            } else if !handshake.wait_handshake() {
              return ConnectRejected
            }
          }
        }
      }
    }
  }
}

///|
fn reserve_optional(
  pool : @budget.Pool?,
  bytes : Int64,
) -> Result[@budget.Ticket?, CloseReason] {
  match pool {
    None => Ok(None)
    Some(pool) =>
      match pool.reserve(bytes) {
        Ok(t) => Ok(Some(t))
        Err(_) => Err(ResourceExhausted)
      }
  }
}

///|
fn release_optional(ticket : @budget.Ticket?) -> Unit {
  if ticket is Some(t) {
    t.release().unwrap()
  }
}

///|
fn resize_optional(
  ticket : @budget.Ticket?,
  pool : @budget.Pool?,
  bytes : Int64,
) -> Result[Unit, CloseReason] {
  match (ticket, pool) {
    (Some(t), Some(p)) =>
      match t.replace([p.allocation(bytes)]) {
        Ok(_) => Ok(())
        Err(_) => Err(ResourceExhausted)
      }
    _ => Ok(())
  }
}

///|
async fn write_transport(
  connection : ConnectionTransport,
  sink : TransportSink,
  bus? : EventBus,
) -> CloseReason {
  let mut control_burst = 0
  for ;; {
    if !sink.ws_closing &&
      control_burst < 4 &&
      sink.take_ws_control() is Some(control) {
      let ticket = sink.take_frame_ticket(control)
      defer release_optional(ticket)
      connection.write_control(control) catch {
        _ => return WriteFailure
      }
      control_burst += 1
      continue
    }
    let command = sink.outbound().get() catch { _ => return ServerShutdown }
    control_burst = 0
    match command {
      WriteWsWake => sink.ws_wake_pending = false
      WriteWsClose(frame) => {
        let ticket = sink.take_frame_ticket(frame)
        defer release_optional(ticket)
        connection.write_control(frame) catch {
          _ => return WriteFailure
        }
        ignore(sink.ws_close_ack.try_put(())) catch {
          _ => ()
        }
        return PeerEof
      }
      WriteFrame(frame) => {
        let (ticket, authorization) = sink.take_owned_frame(frame)
        defer release_optional(ticket)
        if sink.ws_closing {
          continue
        }
        if authorization is Some(value) && !sink.authorize(value) {
          return PolicyRevoked
        }
        connection.write(frame) catch {
          _ => return WriteFailure
        }
        if bus is Some(bus) && bus.needs_promotion {
          bus.post_tick(CheckDeadlines(@async.now()))
        }
      }
      WriteFrameThenClose(frame, reason) => {
        let (ticket, authorization) = sink.take_owned_frame(frame)
        defer release_optional(ticket)
        if sink.ws_closing {
          continue
        }
        if authorization is Some(value) && !sink.authorize(value) {
          return PolicyRevoked
        }
        connection.write(frame) catch {
          _ => return WriteFailure
        }
        return reason
      }
    }
  }
}

///|
async fn supervise_transport(
  connection : ConnectionTransport,
  connection_id : ConnectionId,
  config : ServerConfig,
  events : @async.Queue[DriverEvent],
  bus? : EventBus,
  listener_id? : String = "",
  transport_name? : String = "",
  logger? : @observability.Logger = @observability.Logger::silent(),
) -> Unit {
  let sink = TransportSink::new(config.max_outbound_queue())
  connection.attach_sink(sink)
  let terminal = @async.Queue(kind=Blocking(1))
  let budget = match bus {
    Some(bus) =>
      match bus.register(connection_id, sink) {
        Err(_) => {
          connection.close()
          sink.close()
          terminal.close()
          return
        }
        Ok(budget) => {
          connection.attach_receive_pool(budget.receive)
          Some(budget)
        }
      }
    None => {
      events.put(
        RegisterTransport({ connection_id, sink, accepted_at_ms: @async.now() }),
      ) catch {
        _ => {
          connection.close()
          sink.close()
          terminal.close()
          return
        }
      }
      None
    }
  }
  let reason = @async.with_task_group() <| group => {
    let reader = group.spawn(allow_failure=true) <| () => {
      let reason = read_transport(
        connection,
        connection_id,
        config,
        events,
        bus?,
        budget?,
        sink~,
      )
      try_report_terminal(terminal, reason)
    }
    let writer = group.spawn(allow_failure=true) <| () => {
      let reason = write_transport(connection, sink, bus?)
      try_report_terminal(terminal, reason)
    }
    let closer = group.spawn(allow_failure=true) <| () => {
      let reason = sink.close_signal().get() catch { _ => return }
      try_report_terminal(terminal, reason)
    }
    let reason = terminal.get()
    connection.close()
    sink.close()
    reader.cancel()
    writer.cancel()
    closer.cancel()
    reason
  }
  terminal.close(clear=true)
  if listener_id != "" {
    logger.log(
      @observability.LogRecord::new(
        @async.now(),
        @observability.Debug,
        "listener_connection_closed",
        connection_id=connection_id.value().to_string(),
        listener_id~,
        transport=transport_name,
        reason=close_reason_name(reason),
      ),
    )
  }
  match bus {
    Some(bus) =>
      bus.terminal({ connection_id, reason, observed_at_ms: @async.now() })
    None => {
      events.put(
        Runtime(
          TransportClosed({
            connection_id,
            reason,
            observed_at_ms: @async.now(),
          }),
        ),
      ) catch {
        _ => return
      }
      events.put(UnregisterTransport(connection_id)) catch {
        _ => ()
      }
    }
  }
}

///|
#warnings("-unused_value")
async fn read_connection(
  connection : @socket.Tcp,
  connection_id : ConnectionId,
  config : ServerConfig,
  events : @async.Queue[DriverEvent],
) -> CloseReason {
  read_transport(
    ConnectionTransport::plain(connection),
    connection_id,
    config,
    events,
  )
}

///|
#warnings("-unused_value")
async fn write_connection(
  connection : @socket.Tcp,
  sink : TransportSink,
) -> CloseReason {
  write_transport(ConnectionTransport::plain(connection), sink)
}

///|
pub async fn supervise_connection(
  connection : @socket.Tcp,
  connection_id : ConnectionId,
  config : ServerConfig,
  events : @async.Queue[DriverEvent],
) -> Unit {
  supervise_transport(
    ConnectionTransport::plain(connection),
    connection_id,
    config,
    events,
  )
}
