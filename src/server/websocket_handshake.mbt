///|
pub(all) struct WebSocketPolicy {
  path : String
  allowed_origins : Array[String]
  require_origin : Bool
  max_header_bytes : Int
  max_header_count : Int
  upgrade_timeout_ms : Int
  max_frame_bytes : Int
  max_message_bytes : Int
} derive(Debug, Eq)

///|
fn websocket_valid_origin(origin : String) -> Bool {
  let start = if origin.has_prefix("https://") {
    8
  } else if origin.has_prefix("http://") {
    7
  } else {
    return false
  }
  if origin.length() <= start || origin.length() > 256 {
    return false
  }
  let authority = origin[start:].to_owned()
  for byte in @utf8.encode(authority) {
    let code = byte.to_int()
    if code < 33 ||
      code > 126 ||
      code == 47 ||
      code == 63 ||
      code == 35 ||
      code == 64 ||
      code == 92 {
      return false
    }
  }
  let mut host = authority
  let mut port = ""
  if authority.has_prefix("[") {
    let parts = authority.split("]").to_array()
    if parts.length() != 2 || parts[0].length() < 2 {
      return false
    }
    host = parts[0].to_owned() + "]"
    if parts[1] != "" {
      if !parts[1].has_prefix(":") {
        return false
      }
      port = parts[1][1:].to_owned()
    }
  } else {
    let parts = authority.split(":").to_array()
    if parts.length() > 2 {
      return false
    }
    host = parts[0].to_owned()
    if parts.length() == 2 {
      port = parts[1].to_owned()
    }
  }
  if host == "" || host.contains("..") {
    return false
  }
  if port != "" {
    let number = @string.parse_int(port) catch { _ => return false }
    if number < 1 || number > 65535 || number.to_string() != port {
      return false
    }
  } else if authority.has_suffix(":") {
    return false
  }
  true
}

///|
pub fn WebSocketPolicy::new(
  path? : String = "/mqtt",
  allowed_origins? : Array[String] = [],
  require_origin? : Bool = false,
  max_header_bytes? : Int = 16384,
  max_header_count? : Int = 64,
  upgrade_timeout_ms? : Int = 5000,
  max_frame_bytes? : Int = 1048576,
  max_message_bytes? : Int = 4194304,
) -> WebSocketPolicy? {
  if path == "" ||
    !path.has_prefix("/") ||
    path.contains("?") ||
    path.contains("#") ||
    path.length() > 1024 ||
    max_header_bytes < 1024 ||
    max_header_bytes > 16384 ||
    max_header_count < 1 ||
    max_header_count > 64 ||
    upgrade_timeout_ms < 1 ||
    max_frame_bytes < 1 ||
    max_frame_bytes > 1048576 ||
    max_message_bytes < max_frame_bytes ||
    max_message_bytes > 4194304 {
    return None
  }
  for origin in allowed_origins {
    if !websocket_valid_origin(origin) {
      return None
    }
  }
  Some({
    path,
    allowed_origins,
    require_origin,
    max_header_bytes,
    max_header_count,
    upgrade_timeout_ms,
    max_frame_bytes,
    max_message_bytes,
  })
}

///|
fn websocket_ascii_lower(value : String) -> String {
  let bytes : Array[Byte] = []
  for byte in @utf8.encode(value) {
    let code = byte.to_int()
    bytes.push(
      if code >= 65 && code <= 90 {
        (code + 32).to_byte()
      } else {
        byte
      },
    )
  }
  @utf8.decode(Bytes::from_array(bytes)) catch {
    _ => ""
  }
}

///|
fn websocket_tokens_include(value : String, expected : String) -> Bool {
  for part in value.split(",") {
    if websocket_ascii_lower(part.trim().to_owned()) == expected {
      return true
    }
  }
  false
}

///|
fn websocket_header(
  head : @http_transport.HttpRequestHead,
  name : String,
) -> String? {
  let mut found : String? = None
  for header in head.headers {
    if header.name == name {
      if found is Some(_) {
        return None
      }
      found = Some(header.value)
    }
  }
  found
}

///|
fn websocket_header_count(
  head : @http_transport.HttpRequestHead,
  name : String,
) -> Int {
  let mut count = 0
  for header in head.headers {
    if header.name == name {
      count += 1
    }
  }
  count
}

///|
pub fn websocket_validate_upgrade(
  head : @http_transport.HttpRequestHead,
  policy : WebSocketPolicy,
) -> String? {
  if head.method_name != "GET" ||
    head.target != policy.path ||
    head.content_length.unwrap_or(0) != 0 ||
    websocket_header_count(head, "transfer-encoding") != 0 {
    return None
  }
  for
    name in [
      "host", "upgrade", "connection", "sec-websocket-version", "sec-websocket-key",
      "sec-websocket-protocol", "origin",
    ] {
    if websocket_header_count(head, name) > 1 {
      return None
    }
  }
  if websocket_header(head, "host") is None ||
    !websocket_tokens_include(
      websocket_header(head, "upgrade").unwrap_or(""),
      "websocket",
    ) ||
    !websocket_tokens_include(
      websocket_header(head, "connection").unwrap_or(""),
      "upgrade",
    ) ||
    websocket_header(head, "sec-websocket-version") != Some("13") {
    return None
  }
  let mut mqtt_found = false
  let protocols = websocket_header(head, "sec-websocket-protocol").unwrap_or("")
  for part in protocols.split(",") {
    if part.trim() == "mqtt" {
      mqtt_found = true
    }
  }
  if !mqtt_found {
    return None
  }
  match websocket_header(head, "origin") {
    None => if policy.require_origin { return None }
    Some(origin) =>
      if origin == "null" || !policy.allowed_origins.contains(origin) {
        return None
      }
  }
  let key = websocket_header(head, "sec-websocket-key").unwrap_or("")
  websocket_accept(key)
}

///|
pub fn websocket_upgrade_response(accept : String) -> Bytes {
  @utf8.encode(
    "HTTP/1.1 101 Switching Protocols\r\n" +
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
    "Sec-WebSocket-Accept: " +
    accept +
    "\r\n" +
    "Sec-WebSocket-Protocol: mqtt\r\n\r\n",
  )
}
