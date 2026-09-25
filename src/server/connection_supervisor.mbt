///|
fn recognized_mqtt5_connect(frame : Bytes) -> Bool {
  let reader = @protocol.WireReader::new(frame)
  try {
    if reader.u8() != 0x10 {
      return false
    }
    ignore(reader.vbi())
    reader.utf8() == "MQTT" && reader.u8() == 5
  } catch {
    _ => false
  }
}

///|
fn mqtt5_decode_reason(error : @protocol.WireError) -> Int {
  match error {
    @protocol.Truncated(_)
    | @protocol.MalformedVariableInteger(_)
    | @protocol.InvalidWireString(_) => 0x81
    @protocol.WireLimitExceeded(_) => 0x95
    @protocol.WireInvalidProtocolLevel(_)
    | @protocol.WireInvalidProtocolName(_) => 0x84
    _ => 0x82
  }
}

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
  let mut decode_phase : @protocol.DecodePhase = FirstConnect
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
          let protocol_config = config.protocol_config()
          let limits : @protocol.DecodeLimits = {
            max_packet_bytes: config.max_packet_size(),
            max_property_bytes: protocol_config.max_property_bytes,
            max_user_properties: protocol_config.max_user_properties,
            max_subscription_entries: protocol_config.max_subscription_entries,
          }
          let v5_frame = decode_phase == Established(@protocol.V5) ||
            (decode_phase == FirstConnect && recognized_mqtt5_connect(frame))
          let decode_cost = if v5_frame {
            match
              @protocol.scan_v5_frame_shape(
                frame,
                @protocol.ClientToServer,
                limits,
              ) {
              Ok(shape) => shape.logical_cost()
              Err(_) => decode_cost_bound_v5(frame, protocol_config)
            }
          } else {
            decode_cost_bound(frame)
          }
          let packet_ticket = match reserve_optional(event_pool, decode_cost) {
            Ok(t) => t
            Err(e) => return e
          }
          let mut moved = false
          defer (if !moved { release_optional(packet_ticket) })
          let packet = match
            @protocol.decode_wire(
              frame,
              decode_phase,
              @protocol.PacketDirection::ClientToServer,
              limits,
            ) {
            Err(error) => {
              let malformed_connect = decode_phase == FirstConnect &&
                recognized_mqtt5_connect(frame)
              if !malformed_connect && decode_phase != Established(@protocol.V5) {
                return ProtocolError
              }
              if sink is None {
                return ProtocolError
              }
              let rejected : Mqtt5PacketReceivedEvent = {
                connection_id,
                packet: if malformed_connect {
                  @protocol.Connect5({
                    client_id: "",
                    username: None,
                    password: None,
                    keep_alive: 0,
                    clean_start: true,
                    properties: [],
                    will: None,
                  })
                } else {
                  @protocol.Pingreq5
                },
                received_at_ms: @async.now(),
                rx_permit: None,
                rx_error: Some(mqtt5_decode_reason(error)),
              }
              match (bus, packet_ticket) {
                (Some(bus), Some(ticket)) => {
                  ticket.commit().unwrap()
                  if !bus.post_v5_packet(rejected, ticket) {
                    return ResourceExhausted
                  }
                  moved = true
                }
                _ =>
                  events.put(Runtime(Mqtt5PacketReceived(rejected))) catch {
                    _ => return ServerShutdown
                  }
              }
              if malformed_connect {
                if connection.is_websocket() {
                  let mut resolved : Bool? = None
                  while resolved is None {
                    resolved = sink.unwrap().try_handshake()
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
                } else {
                  ignore(sink.unwrap().wait_handshake())
                }
                return ConnectRejected
              }
              @async.sleep(config.protocol_config().write_timeout_ms + 1000)
              return ProtocolError
            }
            Ok(value) => value
          }
          let is_connect = match packet {
            V311(Connect(_)) => {
              decode_phase = Established(V311)
              true
            }
            V5(Connect5(_)) => {
              decode_phase = Established(V5)
              true
            }
            _ => false
          }
          match packet {
            V311(legacy) => {
              if resize_optional(packet_ticket, event_pool, packet_cost(legacy))
                is Err(e) {
                return e
              }
              if bus is Some(bus) &&
                control_packet(legacy) &&
                !bus.admission.admit_control(connection_id) {
                return RateLimited
              }
              let event = PacketReceivedEvent::{
                connection_id,
                packet: legacy,
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
            }
            V5(value) => {
              if bus is Some(bus) &&
                control_frame(frame) &&
                !bus.admission.admit_control(connection_id) {
                return RateLimited
              }
              let mut rx_permit : RxPermit? = None
              let mut rx_error : Int? = None
              if value is Publish5(publish) &&
                publish.qos != @protocol.QoS0 &&
                sink is Some(transport_sink) {
                let qos = if publish.qos == @protocol.QoS2 { 2 } else { 1 }
                match
                  transport_sink.rx_ledger.reserve(
                    publish.packet_id.unwrap().value(),
                    qos,
                  ) {
                  RxNew(permit) | RxDuplicateQoS2(permit) =>
                    rx_permit = Some(permit)
                  RxPacketIdInUse => rx_error = Some(0x91)
                  RxQuotaExceeded => rx_error = Some(0x93)
                  RxInvalidPacketId => rx_error = Some(0x82)
                }
              }
              let event = Mqtt5PacketReceivedEvent::{
                connection_id,
                packet: value,
                received_at_ms: @async.now(),
                rx_permit,
                rx_error,
              }
              match (bus, packet_ticket) {
                (Some(bus), Some(ticket)) => {
                  ticket.commit().unwrap()
                  if !bus.post_v5_packet(event, ticket) {
                    return ResourceExhausted
                  }
                  moved = true
                }
                _ =>
                  events.put(Runtime(Mqtt5PacketReceived(event))) catch {
                    _ => return ServerShutdown
                  }
              }
            }
          }
          if is_connect && sink is Some(handshake) {
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
  timeout_ms? : Int = 10000,
) -> CloseReason {
  let mut control_burst = 0
  let mut mqtt_control_burst = 0
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
    let (command, prioritized) = sink.next_outbound_command(
      mqtt_control_burst >= 4,
    ) catch {
      _ => return ServerShutdown
    }
    mqtt_control_burst = if prioritized { mqtt_control_burst + 1 } else { 0 }
    control_burst = 0
    match command {
      WritePriorityWake => ()
      OfferDelivery(id) => {
        let offer = match sink.take_delivery_offer(id) {
          Some(value) => value
          None => return WriteFailure
        }
        match write_delivery_offer(connection, sink, bus, offer, timeout_ms) {
          Some(reason) => return reason
          None => ()
        }
      }
      CloseAfterPending(reason) => return reason
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
        let (
          ticket,
          authorization,
          rx_permit,
          alias_proposal,
          logical_v5,
          expiry_deadline,
        ) = sink.take_owned_frame(frame)
        defer release_optional(ticket)
        if sink.ws_closing {
          continue
        }
        if authorization is Some(value) && !sink.authorize(value) {
          return PolicyRevoked
        }
        let gate : (() -> Bool)? = authorization.map(value => {
          () => sink.authorize(value)
        })
        let mut wire_frame = frame
        if logical_v5 is Some(packet) && expiry_deadline is Some(deadline) {
          if packet is Publish5(publish) &&
            !publish.dup &&
            deadline.remaining_at(@budget.monotonic_ms()) == 0L {
            if publish.qos != @protocol.QoS0 {
              let owner = match authorization {
                Some(value) => value
                None => return WriteFailure
              }
              let report = WriteNotStartedEvent::{
                connection_id: owner.connection_id,
                client_id: owner.client_id,
                session_incarnation: owner.session_incarnation,
                packet_id: publish.packet_id.unwrap(),
                delivery_id: match owner.delivery_id {
                  Some(value) if value > 0L => value
                  _ => return WriteFailure
                },
                qos: publish.qos,
              }
              if bus is Some(active) && active.post_write_not_started(report) {
                ()
              } else {
                return WriteFailure
              }
            }
            sink.outbound_alias_cancel(alias_proposal)
            continue
          }
          wire_frame = match
            @protocol.encode_v5(
              mqtt5_refresh_expiry_packet(
                packet,
                deadline,
                @budget.monotonic_ms(),
              ),
              @protocol.ServerToClient,
              frame.length(),
            ) {
            Ok(value) => value
            Err(_) => return WriteFailure
          }
        }
        let written = @async.with_timeout_opt(timeout_ms, () => {
          connection.write(wire_frame, still_allowed?=gate)
        }) catch {
          PolicyWriteRevoked => return PolicyRevoked
          _ => return WriteFailure
        }
        if written is None {
          return WriteFailure
        }
        if rx_permit is Some(permit) {
          ignore(sink.rx_ledger.complete(permit))
        }
        sink.outbound_alias_written(alias_proposal)
        if bus is Some(bus) && bus.needs_promotion {
          bus.post_tick(CheckDeadlines(@async.now()))
        }
      }
      WriteFrameThenClose(frame, reason) => {
        let (
          ticket,
          authorization,
          rx_permit,
          alias_proposal,
          logical_v5,
          expiry_deadline,
        ) = sink.take_owned_frame(frame)
        defer release_optional(ticket)
        if sink.ws_closing {
          continue
        }
        if authorization is Some(value) && !sink.authorize(value) {
          return PolicyRevoked
        }
        let gate : (() -> Bool)? = authorization.map(value => {
          () => sink.authorize(value)
        })
        let mut wire_frame = frame
        if logical_v5 is Some(packet) && expiry_deadline is Some(deadline) {
          if packet is Publish5(publish) &&
            !publish.dup &&
            deadline.remaining_at(@budget.monotonic_ms()) == 0L {
            if publish.qos != @protocol.QoS0 {
              let owner = match authorization {
                Some(value) => value
                None => return WriteFailure
              }
              let report = WriteNotStartedEvent::{
                connection_id: owner.connection_id,
                client_id: owner.client_id,
                session_incarnation: owner.session_incarnation,
                packet_id: publish.packet_id.unwrap(),
                delivery_id: match owner.delivery_id {
                  Some(value) if value > 0L => value
                  _ => return WriteFailure
                },
                qos: publish.qos,
              }
              if bus is Some(active) && active.post_write_not_started(report) {
                ()
              } else {
                return WriteFailure
              }
            }
            sink.outbound_alias_cancel(alias_proposal)
            return reason
          }
          wire_frame = match
            @protocol.encode_v5(
              mqtt5_refresh_expiry_packet(
                packet,
                deadline,
                @budget.monotonic_ms(),
              ),
              @protocol.ServerToClient,
              frame.length(),
            ) {
            Ok(value) => value
            Err(_) => return WriteFailure
          }
        }
        let written = @async.with_timeout_opt(timeout_ms, () => {
          connection.write(wire_frame, still_allowed?=gate)
        }) catch {
          PolicyWriteRevoked => return PolicyRevoked
          _ => return WriteFailure
        }
        if written is None {
          return WriteFailure
        }
        if rx_permit is Some(permit) {
          ignore(sink.rx_ledger.complete(permit))
        }
        sink.outbound_alias_written(alias_proposal)
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
  let sink = TransportSink::new(
    config.max_outbound_queue(),
    receive_maximum=config.protocol_config().server_receive_maximum,
  )
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
      let reason = write_transport(
        connection,
        sink,
        bus?,
        timeout_ms=config.protocol_config().write_timeout_ms,
      )
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
