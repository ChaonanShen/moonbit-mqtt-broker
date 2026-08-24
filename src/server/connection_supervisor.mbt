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
) -> CloseReason {
  let decoder = @framing.FrameDecoder::new(
    config.max_packet_size(),
    config.max_receive_buffer_size(),
  )
  for ;; {
    // The receive limit applies to bytes the decoder has not consumed. Reading
    // no more than the remaining capacity lets a complete prefix be drained
    // before a sticky suffix is admitted on the following iteration.
    let read_capacity = match
      next_read_capacity(decoder, config.max_receive_buffer_size()) {
      Err(reason) => return reason
      Ok(value) => value
    }
    let chunk = connection.read_some(max_len=read_capacity) catch {
      _ => return ReadFailure
    }
    let bytes = match chunk {
      None => return PeerEof
      Some(value) => value
    }
    match decoder.push(bytes[:]) {
      Err(_) => return ProtocolError
      Ok(_) => ()
    }
    for ;; {
      match decoder.next() {
        NeedMoreData => break
        MalformedPacket(_) => return ProtocolError
        CompletePacket(frame) => {
          let packet = match @protocol.decode_packet(frame) {
            Err(_) => return ProtocolError
            Ok(value) => value
          }
          match
            @protocol.validate_direction(
              packet,
              @protocol.PacketDirection::ClientToServer,
            ) {
            Err(_) => return ProtocolError
            Ok(_) => ()
          }
          events.put(
            Runtime(
              PacketReceived({
                connection_id,
                packet,
                received_at_ms: @async.now(),
              }),
            ),
          ) catch {
            _ => return ServerShutdown
          }
        }
      }
    }
  }
}

///|
async fn write_transport(
  connection : ConnectionTransport,
  sink : TransportSink,
) -> CloseReason {
  for ;; {
    let command = sink.outbound().get() catch { _ => return ServerShutdown }
    match command {
      WriteFrame(frame) =>
        connection.write(frame) catch {
          _ => return WriteFailure
        }
      WriteFrameThenClose(frame, reason) => {
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
) -> Unit {
  let sink = TransportSink::new(config.max_outbound_queue())
  let terminal = @async.Queue(kind=Blocking(1))
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
  let reason = @async.with_task_group() <| group => {
    let reader = group.spawn(allow_failure=true) <| () => {
      let reason = read_transport(connection, connection_id, config, events)
      try_report_terminal(terminal, reason)
    }
    let writer = group.spawn(allow_failure=true) <| () => {
      let reason = write_transport(connection, sink)
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
  events.put(
    Runtime(
      TransportClosed({ connection_id, reason, observed_at_ms: @async.now() }),
    ),
  ) catch {
    _ => return
  }
  events.put(UnregisterTransport(connection_id)) catch {
    _ => ()
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
