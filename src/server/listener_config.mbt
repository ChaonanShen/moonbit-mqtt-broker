///|
pub(all) struct ListenerConfig {
  id : String
  listen : String
  max_connections : Int
  tls : TlsServerConfig?
  transport : String
  websocket : WebSocketPolicy?
} derive(Debug, Eq)

///|
pub fn ListenerConfig::new(
  id : String,
  listen : String,
  max_connections : Int,
  tls? : TlsServerConfig,
  transport? : String = "",
  websocket? : WebSocketPolicy,
) -> Result[ListenerConfig, ServerError] {
  if id == "" || id.length() > 64 {
    return Err(
      InvalidConfiguration("listener id must be 1..64 ASCII characters"),
    )
  }
  for char in id {
    let code = char.to_int()
    if !((code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 45 ||
      code == 95) {
      return Err(
        InvalidConfiguration("listener id contains unsupported characters"),
      )
    }
  }
  if listen == "" {
    return Err(InvalidConfiguration("listener address is empty"))
  }
  ignore(@socket.Addr::parse(listen)) catch {
    _ => return Err(InvalidConfiguration("invalid listener address"))
  }
  if max_connections < 1 {
    return Err(
      InvalidConfiguration("listener max_connections must be positive"),
    )
  }
  let effective_transport = if transport == "" {
    if tls is Some(_) {
      "tls"
    } else {
      "tcp"
    }
  } else {
    transport
  }
  match effective_transport {
    "tcp" =>
      if tls is Some(_) || websocket is Some(_) {
        return Err(
          InvalidConfiguration("tcp listener has incompatible settings"),
        )
      }
    "tls" =>
      if tls is None || websocket is Some(_) {
        return Err(
          InvalidConfiguration("tls listener requires only TLS settings"),
        )
      }
    "ws" =>
      if tls is Some(_) || websocket is None {
        return Err(InvalidConfiguration("ws listener requires WS policy"))
      }
    "wss" =>
      if tls is None || websocket is None {
        return Err(
          InvalidConfiguration("wss listener requires TLS and WS policy"),
        )
      }
    _ => return Err(InvalidConfiguration("unknown listener transport"))
  }
  Ok({
    id,
    listen,
    max_connections,
    tls,
    transport: effective_transport,
    websocket,
  })
}

///|
pub(all) struct BoundListener {
  config : ListenerConfig
  socket : @socket.TcpServer
}
