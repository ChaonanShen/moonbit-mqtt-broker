///|
fn websocket_client_frame(opcode : Int, body : Bytes) -> Bytes {
  let data : Array[Byte] = [
    (0x80 | opcode).to_byte(),
    (0x80 | body.length()).to_byte(),
    1,
    2,
    3,
    4,
  ]
  for index in 0..<body.length() {
    data.push((body[index].to_int() ^ (index % 4 + 1)).to_byte())
  }
  Bytes::from_array(data)
}

///|
async test "WS Upgrade routes MQTT bytes and serializes Pong" {
  @async.with_task_group() <| group => {
    let config = loopback_config()
    let socket = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer socket.close()
    let listener = ListenerConfig::new(
      "browser",
      socket.addr.to_string(),
      8,
      transport="ws",
      websocket=WebSocketPolicy::new().unwrap(),
    ).unwrap()
    let mut stopping = false
    let running = group.spawn(allow_failure=true) <| () => {
      serve_listeners(
        [{ config: listener, socket }],
        config,
        loopback_state(config),
        shutdown_requested=() => stopping,
      )
    }
    let client = @socket.Tcp::connect(socket.addr)
    defer client.close()
    client.write(
      b"GET /mqtt HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n",
    )
    let response = client.read_some(max_len=4096).unwrap()
    let text = @utf8.decode(response)
    assert_true(text.contains("101 Switching Protocols"))
    assert_true(text.contains("Sec-WebSocket-Protocol: mqtt"))
    client.write(websocket_client_frame(2, encoded_connect("web-client")))
    assert_eq(client.read_exactly(6), b"\x82\x04\x20\x02\x00\x00")
    client.write(websocket_client_frame(9, b"x"))
    assert_eq(client.read_exactly(3), b"\x8a\x01x")
    client.write(websocket_client_frame(8, b"\x03\xe8"))
    assert_eq(
      @async.with_timeout(1000, () => client.read_exactly(4)),
      b"\x88\x02\x03\xe8",
    )
    client.close()
    stopping = true
    running.wait()
  }
}

///|
async test "WS Upgrade preserves the first masked frame in the same TCP write" {
  @async.with_task_group() <| group => {
    let config = loopback_config()
    let socket = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer socket.close()
    let listener = ListenerConfig::new(
      "browser",
      socket.addr.to_string(),
      8,
      transport="ws",
      websocket=WebSocketPolicy::new().unwrap(),
    ).unwrap()
    let mut stopping = false
    let running = group.spawn(allow_failure=true) <| () => {
      serve_listeners(
        [{ config: listener, socket }],
        config,
        loopback_state(config),
        shutdown_requested=() => stopping,
      )
    }
    let client = @socket.Tcp::connect(socket.addr)
    defer client.close()
    let request = b"GET /mqtt HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n"
    let frame = websocket_client_frame(2, encoded_connect("coalesced"))
    let combined = request.to_array()
    combined.append(frame.to_array())
    client.write(Bytes::from_array(combined))
    let response = websocket_upgrade_response("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    assert_eq(client.read_exactly(response.length()), response)
    assert_eq(client.read_exactly(6), b"\x82\x04\x20\x02\x00\x00")
    client.close()
    stopping = true
    running.wait()
  }
}

///|
async test "WSS Upgrade and MQTT CONNACK use a verified TLS client" {
  let fixture = @fs.tmpdir(prefix="mqtt-wss-test-")
  let cert = fixture + "/server.crt"
  let key = fixture + "/server.key"
  let (openssl_status, _, _) = @process.collect_output("openssl", [
    "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "1", "-subj",
    "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-keyout",
    key, "-out", cert,
  ])
  assert_eq(openssl_status, 0)
  @fs.chmod(key, 0o600)
  @async.with_task_group() <| group => {
    let config = loopback_config()
    let socket = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer socket.close()
    let listener = ListenerConfig::new(
      "secure-browser",
      socket.addr.to_string(),
      8,
      tls=TlsServerConfig::new(cert, key).unwrap(),
      transport="wss",
      websocket=WebSocketPolicy::new().unwrap(),
    ).unwrap()
    let mut stopping = false
    let running = group.spawn(allow_failure=true) <| () => {
      serve_listeners(
        [{ config: listener, socket }],
        config,
        loopback_state(config),
        shutdown_requested=() => stopping,
      )
    }
    let tcp = @socket.Tcp::connect(socket.addr)
    defer tcp.close()
    let client = @tls.Tls::client(
      tcp,
      host="localhost",
      trust=@tls.CustomPemFile(cert),
    )
    defer client.close()
    client.write(
      b"GET /mqtt HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n",
    )
    let response = @utf8.decode(client.read_some(max_len=4096).unwrap())
    assert_true(response.contains("101 Switching Protocols"))
    client.write(websocket_client_frame(2, encoded_connect("wss-client")))
    assert_eq(client.read_exactly(6), b"\x82\x04\x20\x02\x00\x00")
    client.close()
    stopping = true
    running.wait()
  }
  @fs.rmdir(fixture, recursive=true)
}

///|
async test "single WS listener accepts one connection in once mode" {
  @async.with_task_group() <| group => {
    let config = loopback_config()
    let socket = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer socket.close()
    let running = group.spawn(allow_failure=true) <| () => {
      serve_once(
        socket,
        config,
        loopback_state(config),
        websocket=WebSocketPolicy::new().unwrap(),
      )
    }
    let client = @socket.Tcp::connect(socket.addr)
    defer client.close()
    client.write(
      b"GET /mqtt HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n",
    )
    let response = websocket_upgrade_response("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    assert_eq(client.read_exactly(response.length()), response)
    client.write(websocket_client_frame(2, encoded_connect("once-ws")))
    assert_eq(client.read_exactly(6), b"\x82\x04\x20\x02\x00\x00")
    client.write(websocket_client_frame(8, b"\x03\xe8"))
    assert_eq(client.read_exactly(4), b"\x88\x02\x03\xe8")
    running.wait()
  }
}

///|
async test "WS CONNECT plus QoS1 PUBLISH preserves CONNACK ordering" {
  @async.with_task_group() <| group => {
    let config = loopback_config()
    let socket = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer socket.close()
    let listener = ListenerConfig::new(
      "browser",
      socket.addr.to_string(),
      8,
      transport="ws",
      websocket=WebSocketPolicy::new().unwrap(),
    ).unwrap()
    let mut stopping = false
    let running = group.spawn(allow_failure=true) <| () => {
      serve_listeners(
        [{ config: listener, socket }],
        config,
        loopback_state(config),
        shutdown_requested=() => stopping,
      )
    }
    let client = @socket.Tcp::connect(socket.addr)
    defer client.close()
    client.write(
      b"GET /mqtt HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n",
    )
    let response = websocket_upgrade_response("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    assert_eq(client.read_exactly(response.length()), response)
    let mqtt = encoded_connect("gate-ws").to_array()
    mqtt.append(b"\x32\x09\x00\x04gate\x00\x01x".to_array())
    client.write(websocket_client_frame(2, Bytes::from_array(mqtt)))
    assert_eq(client.read_exactly(6), b"\x82\x04\x20\x02\x00\x00")
    assert_eq(client.read_exactly(6), b"\x82\x04\x40\x02\x00\x01")
    client.close()
    stopping = true
    running.wait()
  }
}
