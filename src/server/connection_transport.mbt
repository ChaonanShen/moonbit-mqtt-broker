///|
priv enum RawTransport {
  Plain(@socket.Tcp)
  Secure(@tls.Tls, @socket.Tcp)
}

///|
priv struct WebSocketStream {
  raw : RawTransport
  decoder : WebSocketDecoder
  mut pending : Bytes
  mut pending_offset : Int
  mut deferred_data : Array[Byte]
  mut suffix : Bytes
  mut sink : TransportSink?
  mut receive_pool : @budget.Pool?
  mut receive_ticket : @budget.Ticket?
  bus : EventBus
  connection_id : ConnectionId
}

///|
priv enum ConnectionTransport {
  Raw(RawTransport)
  WebSocket(WebSocketStream)
}

///|
async fn ConnectionTransport::secure(
  connection : @socket.Tcp,
  config : TlsServerConfig,
) -> ConnectionTransport {
  let encrypted = @async.with_timeout(config.handshake_timeout_ms(), () => {
    @tls.Tls::server(
      connection,
      private_key_file=config.private_key_file(),
      private_key_type=@tls.PEM,
      certificate_file=config.certificate_file(),
      certificate_type=@tls.PEM,
    )
  })
  Raw(Secure(encrypted, connection))
}

///|
fn ConnectionTransport::plain(connection : @socket.Tcp) -> ConnectionTransport {
  Raw(Plain(connection))
}

///|
async fn RawTransport::read_some(self : RawTransport, max_len~ : Int) -> Bytes? {
  match self {
    Plain(connection) => connection.read_some(max_len~)
    Secure(encrypted, _) => encrypted.read_some(max_len~)
  }
}

///|
async fn RawTransport::write(self : RawTransport, bytes : Bytes) -> Unit {
  match self {
    Plain(connection) => connection.write(bytes)
    Secure(encrypted, _) => encrypted.write(bytes)
  }
}

///|
fn RawTransport::close(self : RawTransport) -> Unit {
  match self {
    Plain(connection) => connection.close()
    Secure(encrypted, connection) => {
      encrypted.close()
      connection.close()
    }
  }
}

///|
async fn ConnectionTransport::upgrade(
  self : ConnectionTransport,
  policy : WebSocketPolicy,
  bus : EventBus,
  connection_id : ConnectionId,
) -> ConnectionTransport {
  let raw = match self {
    Raw(value) => value
    WebSocket(_) => raise ResourceStartupFailure("duplicate WS upgrade")
  }
  @async.with_timeout(policy.upgrade_timeout_ms, () => {
    let parser = @http_transport.HttpParser::new(
      policy.max_header_bytes,
      policy.max_header_count,
    )
    for ;; {
      let available = policy.max_header_bytes - parser.buffered_bytes()
      if available <= 0 {
        raise ResourceStartupFailure("WS request headers too large")
      }
      let chunk = raw.read_some(
        max_len=if available < 4096 { available } else { 4096 },
      )
      let bytes = match chunk {
        None => raise ResourceStartupFailure("WS request closed before Upgrade")
        Some(value) => value
      }
      if !bus.admission.admit_ingress(connection_id, bytes.length().to_int64()) {
        raise ResourceStartupFailure("WS Upgrade rate limited")
      }
      match parser.feed(bytes) {
        NeedMore => ()
        Reject(_) => {
          raw.write(
            b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
          )
          raise ResourceStartupFailure("invalid WS request")
        }
        Complete(head, consumed) => {
          let accept = match websocket_validate_upgrade(head, policy) {
            None => {
              raw.write(
                b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
              )
              raise ResourceStartupFailure("WS Upgrade rejected")
            }
            Some(value) => value
          }
          raw.write(websocket_upgrade_response(accept))
          let suffix = Bytes::from_array(bytes.to_array()[consumed:].to_owned())
          return WebSocket({
            raw,
            decoder: WebSocketDecoder::new(
              policy.max_frame_bytes,
              policy.max_message_bytes,
            ),
            pending: b"",
            pending_offset: 0,
            deferred_data: [],
            suffix,
            sink: None,
            receive_pool: None,
            receive_ticket: None,
            bus,
            connection_id,
          })
        }
      }
    }
  })
}

///|
fn ConnectionTransport::attach_sink(
  self : ConnectionTransport,
  sink : TransportSink,
) -> Unit {
  match self {
    WebSocket(stream) => stream.sink = Some(sink)
    Raw(_) => ()
  }
}

///|
fn ConnectionTransport::attach_receive_pool(
  self : ConnectionTransport,
  pool : @budget.Pool,
) -> Unit {
  match self {
    WebSocket(stream) => stream.receive_pool = Some(pool)
    Raw(_) => ()
  }
}

///|
fn WebSocketStream::account(
  self : WebSocketStream,
  next_read : Int,
) -> Unit raise ResourceStartupFailure {
  let retained = self.decoder.buffered_len() +
    self.pending.length() -
    self.pending_offset +
    self.deferred_data.length() +
    self.suffix.length()
  let size = (retained + next_read).to_int64() * 3L
  match self.receive_pool {
    None => ()
    Some(pool) =>
      match self.receive_ticket {
        None =>
          match pool.reserve(size) {
            Ok(ticket) => self.receive_ticket = Some(ticket)
            Err(_) =>
              raise ResourceStartupFailure("WS receive budget exhausted")
          }
        Some(ticket) =>
          match ticket.replace([pool.allocation(size)]) {
            Ok(_) => ()
            Err(_) =>
              raise ResourceStartupFailure("WS receive budget exhausted")
          }
      }
  }
}

///|
async fn WebSocketStream::read_some(
  self : WebSocketStream,
  max_len : Int,
) -> Bytes? {
  for ;; {
    self.account(0)
    if self.pending_offset >= self.pending.length() {
      self.pending = b""
      self.pending_offset = 0
    }
    if self.pending_offset < self.pending.length() {
      let end = if self.pending.length() - self.pending_offset < max_len {
        self.pending.length()
      } else {
        self.pending_offset + max_len
      }
      let result = Bytes::from_array(
        self.pending.to_array()[self.pending_offset:end].to_owned(),
      )
      self.pending_offset = end
      return Some(result)
    }
    if !self.deferred_data.is_empty() {
      let end = if self.deferred_data.length() < max_len {
        self.deferred_data.length()
      } else {
        max_len
      }
      let result = Bytes::from_array(self.deferred_data[:end].to_owned())
      self.deferred_data = self.deferred_data[end:].to_owned()
      return Some(result)
    }
    match self.decoder.next() {
      WsNeedMore =>
        if self.suffix.length() > 0 {
          let suffix = self.suffix
          self.suffix = b""
          if !self.decoder.feed(suffix) {
            raise ResourceStartupFailure("WS receive buffer exceeded")
          }
        } else {
          let next_read = if max_len < 4096 { max_len } else { 4096 }
          self.account(next_read)
          let chunk = self.raw.read_some(max_len=next_read)
          match chunk {
            None => return None
            Some(bytes) => {
              if !self.bus.admission.admit_ingress(
                  self.connection_id,
                  bytes.length().to_int64(),
                ) {
                raise ResourceStartupFailure("WS ingress rate limited")
              }
              if !self.decoder.feed(bytes) {
                raise ResourceStartupFailure("WS receive buffer exceeded")
              }
            }
          }
        }
      WsBinary(bytes) => {
        if bytes.length() == 0 &&
          !self.bus.admission.admit_control(self.connection_id) {
          raise ResourceStartupFailure("WS empty frame rate limited")
        }
        self.pending = bytes
        self.pending_offset = 0
      }
      WsPing(bytes) => {
        if !self.bus.admission.admit_control(self.connection_id) {
          raise ResourceStartupFailure("WS Ping rate limited")
        }
        let frame = websocket_encode_frame(9 + 1, bytes).unwrap()
        if self.sink is Some(sink) && !sink.enqueue_ws_control(frame) {
          raise ResourceStartupFailure("WS control queue full")
        }
      }
      WsPong =>
        if !self.bus.admission.admit_control(self.connection_id) {
          raise ResourceStartupFailure("WS Pong rate limited")
        }
      WsClose(bytes) => {
        let frame = websocket_encode_frame(8, bytes).unwrap()
        if self.sink is Some(sink) {
          if sink.enqueue_ws_close(frame) {
            sink.wait_ws_close()
          }
        }
        return None
      }
      WsInvalid(code) => {
        let payload = Bytes::from_array([
          (code >> 8).to_byte(),
          (code & 0xff).to_byte(),
        ])
        let frame = websocket_encode_frame(8, payload).unwrap()
        if self.sink is Some(sink) {
          if sink.enqueue_ws_close(frame) {
            sink.wait_ws_close()
          }
        }
        raise ResourceStartupFailure("invalid WS frame")
      }
    }
  }
}

///|
async fn ConnectionTransport::drain_buffered_controls(
  self : ConnectionTransport,
  remaining_budget : Int,
) -> CloseReason? {
  let stream = match self {
    Raw(_) => return None
    WebSocket(value) => value
  }
  for ;; {
    match stream.decoder.next() {
      WsNeedMore => return None
      WsBinary(bytes) => {
        let held = stream.pending.length() -
          stream.pending_offset +
          stream.deferred_data.length()
        if held + bytes.length() > remaining_budget {
          return Some(ResourceExhausted)
        }
        if bytes.length() == 0 &&
          !stream.bus.admission.admit_control(stream.connection_id) {
          return Some(RateLimited)
        }
        stream.deferred_data.append(bytes.to_array())
        stream.account(0) catch {
          _ => return Some(ResourceExhausted)
        }
      }
      WsPing(bytes) => {
        if !stream.bus.admission.admit_control(stream.connection_id) {
          return Some(RateLimited)
        }
        let frame = websocket_encode_frame(10, bytes).unwrap()
        if stream.sink is Some(sink) && !sink.enqueue_ws_control(frame) {
          return Some(ResourceExhausted)
        }
      }
      WsPong =>
        if !stream.bus.admission.admit_control(stream.connection_id) {
          return Some(RateLimited)
        }
      WsClose(bytes) => {
        let frame = websocket_encode_frame(8, bytes).unwrap()
        if stream.sink is Some(sink) && sink.enqueue_ws_close(frame) {
          sink.wait_ws_close()
        }
        return Some(PeerEof)
      }
      WsInvalid(code) => {
        let payload = Bytes::from_array([
          (code >> 8).to_byte(),
          (code & 0xff).to_byte(),
        ])
        let frame = websocket_encode_frame(8, payload).unwrap()
        if stream.sink is Some(sink) && sink.enqueue_ws_close(frame) {
          sink.wait_ws_close()
        }
        return Some(ProtocolError)
      }
    }
  }
}

///|
fn ConnectionTransport::is_websocket(self : ConnectionTransport) -> Bool {
  self is WebSocket(_)
}

///|
async fn ConnectionTransport::read_some(
  self : ConnectionTransport,
  max_len~ : Int,
) -> Bytes? {
  match self {
    Raw(raw) => raw.read_some(max_len~)
    WebSocket(stream) => stream.read_some(max_len)
  }
}

///|
suberror PolicyWriteRevoked {
  PolicyWriteRevoked
} derive(Debug)

///|
async fn ConnectionTransport::write(
  self : ConnectionTransport,
  bytes : Bytes,
  still_allowed? : () -> Bool,
) -> Unit {
  match self {
    Raw(raw) =>
      if still_allowed is None {
        raw.write(bytes)
      } else {
        let gate = still_allowed.unwrap()
        let mut offset = 0
        while offset < bytes.length() {
          if !gate() {
            raise PolicyWriteRevoked
          }
          let end = if bytes.length() - offset < 16384 {
            bytes.length()
          } else {
            offset + 16384
          }
          raw.write(Bytes::from_array(bytes[offset:end].to_array()))
          offset = end
        }
      }
    WebSocket(stream) => {
      let mut offset = 0
      while offset < bytes.length() {
        if still_allowed is Some(gate) && !gate() {
          raise PolicyWriteRevoked
        }
        let end = if bytes.length() - offset < 16384 {
          bytes.length()
        } else {
          offset + 16384
        }
        let payload = Bytes::from_array(bytes[offset:end].to_array())
        stream.raw.write(websocket_encode_frame(2, payload).unwrap())
        offset = end
        if stream.sink is Some(sink) {
          if sink.ws_closing {
            break
          }
          for _ in 0..<2 {
            match sink.take_ws_control() {
              None => break
              Some(control) => {
                let ticket = sink.take_frame_ticket(control)
                defer release_optional(ticket)
                stream.raw.write(control)
              }
            }
          }
          if sink.ws_closing {
            break
          }
        }
      }
    }
  }
}

///|
async fn ConnectionTransport::write_control(
  self : ConnectionTransport,
  bytes : Bytes,
) -> Unit {
  match self {
    Raw(raw) => raw.write(bytes)
    WebSocket(stream) => stream.raw.write(bytes)
  }
}

///|
fn ConnectionTransport::close(self : ConnectionTransport) -> Unit {
  match self {
    Raw(raw) => raw.close()
    WebSocket(stream) => {
      if stream.receive_ticket is Some(ticket) {
        ticket.release().unwrap()
        stream.receive_ticket = None
      }
      stream.raw.close()
    }
  }
}
