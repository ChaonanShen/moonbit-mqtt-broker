///|
pub struct HttpParser {
  limit : Int
  max_fields : Int
  raw : Array[Byte]
  mut line_count : Int
  mut finished : Bool
}

///|
pub fn HttpParser::new(
  max_header_bytes : Int,
  max_header_count : Int,
) -> HttpParser {
  {
    limit: max_header_bytes,
    max_fields: max_header_count,
    raw: [],
    line_count: 0,
    finished: false,
  }
}

///|
pub fn HttpParser::buffered_bytes(self : HttpParser) -> Int {
  self.raw.length()
}

///|
fn http_token_byte(code : Int) -> Bool {
  if (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) {
    return true
  }
  match code {
    33
    | 35
    | 36
    | 37
    | 38
    | 39
    | 42
    | 43
    | 45
    | 46
    | 94
    | 95
    | 96
    | 124
    | 126 => true
    _ => false
  }
}

///|
fn http_header_name_lower(value : String) -> String? {
  if value == "" {
    return None
  }
  let encoded = @utf8.encode(value)
  let lower : Array[Byte] = []
  for byte in encoded {
    let code = byte.to_int()
    if !http_token_byte(code) {
      return None
    }
    lower.push(
      if code >= 65 && code <= 90 {
        (code + 32).to_byte()
      } else {
        byte
      },
    )
  }
  let name = @utf8.decode(Bytes::from_array(lower)) catch { _ => return None }
  Some(name)
}

///|
fn strict_content_length(value : String) -> Int? {
  if value == "" {
    return None
  }
  for digit in value {
    if digit.to_int() < 48 || digit.to_int() > 57 {
      return None
    }
  }
  let parsed = @string.parse_int(value) catch { _ => return None }
  if parsed < 0 {
    None
  } else {
    Some(parsed)
  }
}

///|
fn HttpParser::parse_head(self : HttpParser) -> HttpParseResult {
  let text = @utf8.decode(Bytes::from_array(self.raw.copy())) catch {
    _ => return Reject(BadRequest)
  }
  let lines = text.split("\r\n").to_array()
  if lines.length() < 3 ||
    lines[lines.length() - 1] != "" ||
    lines[lines.length() - 2] != "" {
    return Reject(BadRequest)
  }
  let request_line = lines[0].to_owned()
  let words = request_line.split(" ").to_array()
  if words.length() != 3 ||
    words[0] == "" ||
    words[1] == "" ||
    words[2] != "HTTP/1.1" {
    return Reject(BadRequest)
  }
  let method_name = words[0].to_owned()
  for byte in @utf8.encode(method_name) {
    if !http_token_byte(byte.to_int()) {
      return Reject(BadRequest)
    }
  }
  let target = words[1].to_owned()
  if target.length() < 1 || target.length() > 1024 || target[0].to_int() != 47 {
    return Reject(BadRequest)
  }
  for byte in @utf8.encode(target) {
    if byte.to_int() < 33 || byte.to_int() > 126 || byte.to_int() == 35 {
      return Reject(BadRequest)
    }
  }
  let headers : Array[HttpHeader] = []
  let mut host_seen = false
  let mut authorization_seen = false
  let mut transfer_encoding_seen = false
  let mut content_length : Int? = None
  for index in 1..<(lines.length() - 2) {
    if headers.length() >= self.max_fields {
      return Reject(TooManyHeaders)
    }
    let line = lines[index].to_owned()
    if line.length() < 1 || line.length() > 2048 || line[0].to_int() == 32 {
      return Reject(BadRequest)
    }
    let mut colon = -1
    for offset in 0..<line.length() {
      if line[offset].to_int() == 58 {
        colon = offset
        break
      }
    }
    if colon < 1 {
      return Reject(BadRequest)
    }
    let name = match http_header_name_lower(line[:colon].to_owned()) {
      Some(value) => value
      None => return Reject(BadRequest)
    }
    let value = line[colon + 1:].to_owned().trim().to_owned()
    match name {
      "host" => {
        if host_seen || value == "" || value.contains(" ") {
          return Reject(BadRequest)
        }
        host_seen = true
      }
      "authorization" => {
        if authorization_seen {
          return Reject(BadRequest)
        }
        authorization_seen = true
      }
      "content-length" => {
        if content_length is Some(_) {
          return Reject(InvalidLength)
        }
        content_length = match strict_content_length(value) {
          Some(number) => Some(number)
          None => return Reject(InvalidLength)
        }
      }
      "transfer-encoding" => transfer_encoding_seen = true
      _ => ()
    }
    headers.push({ name, value })
  }
  if !host_seen || (transfer_encoding_seen && content_length is Some(_)) {
    return Reject(BadRequest)
  }
  Complete(
    { method_name, target, version: "HTTP/1.1", headers, content_length },
    0,
  )
}

///|
/// Feed only the next socket chunk. Complete's Int is the number of bytes
/// consumed from this chunk; the caller retains chunk[consumed:] as suffix.
pub fn HttpParser::feed(self : HttpParser, chunk : Bytes) -> HttpParseResult {
  if self.finished {
    return Reject(BadRequest)
  }
  for offset in 0..<chunk.length() {
    let byte = chunk[offset]
    let code = byte.to_int()
    let length = self.raw.length()
    let previous = if length > 0 { self.raw[length - 1].to_int() } else { -1 }
    if code > 126 ||
      (code < 32 && code != 10 && code != 13) ||
      (code == 10 && previous != 13) ||
      (previous == 13 && code != 10) {
      self.finished = true
      return Reject(BadRequest)
    }
    if length >= self.limit {
      self.finished = true
      return Reject(HeaderTooLarge)
    }
    self.raw.push(byte)
    let new_length = self.raw.length()
    let terminated = new_length >= 4 &&
      self.raw[new_length - 4] == 13 &&
      self.raw[new_length - 3] == 10 &&
      self.raw[new_length - 2] == 13 &&
      self.raw[new_length - 1] == 10
    if code == 10 {
      self.line_count += 1
      if self.line_count > self.max_fields + 2 ||
        (!terminated && self.line_count > self.max_fields + 1) {
        self.finished = true
        return Reject(TooManyHeaders)
      }
    }
    if terminated {
      self.finished = true
      match self.parse_head() {
        Complete(head, _) => return Complete(head, offset + 1)
        error => return error
      }
    }
  }
  NeedMore
}
