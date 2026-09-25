///|
fn ManagementHttp::parse_failure_response(
  self : ManagementHttp,
  error : @http_transport.HttpParseError,
) -> Bytes {
  let id = self.request_id().unwrap_or("unavailable")
  match error {
    @http_transport.HeaderTooLarge =>
      self.reject(
        @http_transport.BodyTooLarge,
        "header_too_large",
        id,
        @management.RejectedParse,
      )
    _ =>
      self.reject(
        @http_transport.BadRequest,
        "bad_request",
        id,
        @management.RejectedParse,
      )
  }
}

///|
async fn ManagementHttp::write_bounded(
  self : ManagementHttp,
  connection : @socket.Tcp,
  response : Bytes,
) -> Unit {
  let result = @async.with_timeout_opt(self.config.write_timeout_ms(), () => {
    connection.write(response)
  }) catch {
    _ => {
      self.rejections.record(@management.RejectedOther)
      return
    }
  }
  if result is None {
    self.rejections.record(@management.RejectedDeadline)
  }
}

///|
/// One request and one response, with no keepalive or second request decode.
/// This function runs under the absolute outer request timeout.
async fn ManagementHttp::serve_one_request(
  self : ManagementHttp,
  connection : @socket.Tcp,
) -> Unit {
  let parser = @http_transport.HttpParser::new(
    self.config.max_header_bytes(),
    self.config.max_header_count(),
  )
  for ;; {
    let remaining = self.config.max_header_bytes() - parser.buffered_bytes()
    if remaining <= 0 {
      self.write_bounded(
        connection,
        self.parse_failure_response(@http_transport.HeaderTooLarge),
      )
      return
    }
    let read_size = if remaining < 1024 { remaining } else { 1024 }
    let chunk = match connection.read_some(max_len=read_size) {
      Some(value) => value
      None => return
    }
    match parser.feed(chunk) {
      @http_transport.NeedMore => ()
      @http_transport.Reject(error) => {
        self.write_bounded(connection, self.parse_failure_response(error))
        return
      }
      @http_transport.Complete(head, consumed) => {
        let response = if head.target == "/v1/config/reload" &&
          head.method_name == "POST" {
          let (body, extra) = read_reload_body(
            connection, head, chunk, consumed,
          )
          self.respond_command(head, extra, @budget.monotonic_ms(), body?)
        } else if head.target.has_prefix("/v1/") &&
          (head.method_name == "POST" || head.method_name == "DELETE") {
          self.respond_command(
            head,
            chunk.length() - consumed,
            @budget.monotonic_ms(),
          )
        } else if head.target == "/v1/config" &&
          self.reload_generation is Some(_) {
          self.respond_reload_config(
            head,
            chunk.length() - consumed,
            @budget.monotonic_ms(),
          )
        } else if head.target.has_prefix("/v1/operations/") ||
          head.target == "/v1/audit" ||
          head.target.has_prefix("/v1/audit?") {
          self.respond_operation(
            head,
            chunk.length() - consumed,
            @budget.monotonic_ms(),
          )
        } else if head.target.has_prefix("/v1/") && head.target != "/v1/status" {
          self.respond_details(
            head,
            chunk.length() - consumed,
            @budget.monotonic_ms(),
          )
        } else {
          self.respond(head, chunk.length() - consumed, @budget.monotonic_ms())
        }
        self.write_bounded(connection, response)
        return
      }
    }
  }
}

///|
/// The caller owns the accepted loopback socket. A slot remains owned until
/// the actual read/write coroutine has ended, even on timeout or cancellation.
pub async fn ManagementHttp::serve_connection(
  self : ManagementHttp,
  connection : @socket.Tcp,
) -> Unit {
  defer connection.close()
  let lease = match self.budget.acquire() {
    Some(value) => value
    None => {
      self.rejections.record(@management.RejectedCapacity)
      return
    }
  }
  defer ignore(lease.release())
  if !self.admit_connection(@budget.monotonic_ms()) {
    return
  }
  let completed = @async.with_timeout_opt(self.config.request_timeout_ms(), () => {
    self.serve_one_request(connection)
  }) catch {
    _ => {
      self.rejections.record(@management.RejectedOther)
      return
    }
  }
  if completed is None {
    self.rejections.record(@management.RejectedDeadline)
  }
}

///|
/// Only the reload route accepts a body. The outer request timeout already
/// bounds these reads; the fixed 4096-byte limit prevents unbounded buffering.
async fn read_reload_body(
  connection : @socket.Tcp,
  head : @http_transport.HttpRequestHead,
  chunk : Bytes,
  consumed : Int,
) -> (Bytes?, Int) {
  let length = head.content_length.unwrap_or(0)
  if length < 0 || length > 4096 {
    return (None, 0)
  }
  let suffix = chunk.length() - consumed
  if suffix < 0 || suffix > length {
    return (None, if suffix > length { suffix - length } else { 1 })
  }
  let bytes : Array[Byte] = []
  for index in consumed..<chunk.length() {
    bytes.push(chunk[index])
  }
  while bytes.length() < length {
    let remaining = length - bytes.length()
    let next = connection.read_some(
      max_len=if remaining < 1024 { remaining } else { 1024 },
    ) catch {
      _ => return (None, 0)
    }
    match next {
      Some(value) if value.length() > 0 && value.length() <= remaining =>
        for byte in value {
          bytes.push(byte)
        }
      _ => return (None, 0)
    }
  }
  (Some(Bytes::from_array(bytes)), 0)
}
