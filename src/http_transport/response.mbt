///|
pub(all) enum HttpStatus {
  Ok
  Accepted
  BadRequest
  Unauthorized
  Forbidden
  NotFound
  MethodNotAllowed
  Conflict
  Expired
  PreconditionFailed
  BodyTooLarge
  Unprocessable
  UnsupportedMediaType
  PreconditionRequired
  TooManyRequests
  InternalServerError
  NotImplemented
  ServiceUnavailable
} derive(Eq, Debug)

///|
pub(all) enum HttpBodyType {
  JsonBody
  PrometheusBody
  PlainBody
} derive(Eq, Debug)

///|
pub(all) enum HttpAllow {
  AllowGet
  AllowPost
  AllowDelete
} derive(Eq, Debug)

///|
pub(all) enum HttpEncodeError {
  ResponseTooLarge
  ResponseHeaderTooLarge
} derive(Eq, Debug)

///|
fn status_line(status : HttpStatus) -> String {
  match status {
    Ok => "200 OK"
    Accepted => "202 Accepted"
    BadRequest => "400 Bad Request"
    Unauthorized => "401 Unauthorized"
    Forbidden => "403 Forbidden"
    NotFound => "404 Not Found"
    MethodNotAllowed => "405 Method Not Allowed"
    Conflict => "409 Conflict"
    Expired => "410 Gone"
    PreconditionFailed => "412 Precondition Failed"
    BodyTooLarge => "413 Content Too Large"
    Unprocessable => "422 Unprocessable Content"
    UnsupportedMediaType => "415 Unsupported Media Type"
    PreconditionRequired => "428 Precondition Required"
    TooManyRequests => "429 Too Many Requests"
    InternalServerError => "500 Internal Server Error"
    NotImplemented => "501 Not Implemented"
    ServiceUnavailable => "503 Service Unavailable"
  }
}

///|
fn content_type_name(value : HttpBodyType) -> String {
  match value {
    JsonBody => "application/json"
    PrometheusBody => "text/plain; version=0.0.4; charset=utf-8"
    PlainBody => "text/plain; charset=utf-8"
  }
}

///|
fn allowed_method(value : HttpAllow) -> String {
  match value {
    AllowGet => "GET"
    AllowPost => "POST"
    AllowDelete => "DELETE"
  }
}

///|
/// Each response is one HTTP/1.1 message and ends the connection. The body
/// limit counts the supplied bytes; fixed headers are separately capped at
/// 1024 bytes and charged to the request workspace.
pub fn encode_response(
  status : HttpStatus,
  body_type : HttpBodyType,
  body : Bytes,
  max_body_bytes : Int,
  allow? : HttpAllow,
  location? : String,
) -> Result[Bytes, HttpEncodeError] {
  if max_body_bytes < 0 || body.length() > max_body_bytes {
    return Err(ResponseTooLarge)
  }
  let mut header = "HTTP/1.1 " +
    status_line(status) +
    "\r\n" +
    "Content-Type: " +
    content_type_name(body_type) +
    "\r\n" +
    "Content-Length: " +
    body.length().to_string() +
    "\r\n" +
    "Connection: close\r\n" +
    "Cache-Control: no-store\r\n"
  if status == Unauthorized {
    header = header + "WWW-Authenticate: Bearer\r\n"
  }
  if status == MethodNotAllowed && allow is Some(permitted) {
    header = header + "Allow: " + allowed_method(permitted) + "\r\n"
  }
  if location is Some(value) {
    if value.length() > 256 || value.contains("\r") || value.contains("\n") {
      return Err(ResponseHeaderTooLarge)
    }
    header = header + "Location: " + value + "\r\n"
  }
  header = header + "\r\n"
  let header_bytes = @utf8.encode(header)
  if header_bytes.length() > 1024 {
    return Err(ResponseHeaderTooLarge)
  }
  let output : Array[Byte] = []
  for byte in header_bytes {
    output.push(byte)
  }
  for byte in body {
    output.push(byte)
  }
  Ok(Bytes::from_array(output))
}
