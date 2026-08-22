///|
fn supervisor_failure_config() -> ServerConfig {
  let broker = @router.BrokerConfig::new(4, 8, 4).unwrap()
  ServerConfig::new(2, 1024, 1024, 2, 8, 500, 20, broker).unwrap()
}

///|
async test "closed socket maps reader and writer io failures" {
  // A locally closed read handle is classified as ReadFailure rather than EOF.
  {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    let client = @socket.Tcp::connect(listener.addr)
    defer client.close()
    let (connection, _) = listener.accept()
    connection.close()
    let events = @async.Queue(kind=Blocking(1))
    defer events.close(clear=true)
    assert_eq(
      read_connection(
        connection,
        ConnectionId::new(81L),
        supervisor_failure_config(),
        events,
      ),
      ReadFailure,
    )
  }

  // A queued frame written through a locally closed handle is WriteFailure.
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  let client = @socket.Tcp::connect(listener.addr)
  defer client.close()
  let (connection, _) = listener.accept()
  connection.close()
  let sink = TransportSink::new(1)
  defer sink.close()
  sink.outbound().put(WriteFrame(b"write-after-close"))
  assert_eq(write_connection(connection, sink), WriteFailure)
}
