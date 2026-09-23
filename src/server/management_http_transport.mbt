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
        let response = self.respond(
          head,
          chunk.length() - consumed,
          @budget.monotonic_ms(),
        )
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
