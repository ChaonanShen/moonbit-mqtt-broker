///|

///|
/// Compatibility entry point retained for the CONNECT loopback smoke tests.
pub async fn serve_one(
  listener : @socket.TcpServer,
  max_packet_size : Int,
) -> Unit {
  let broker_config = @router.BrokerConfig::new(128, 16384, 1024).unwrap()
  let config = ServerConfig::new(
    1, max_packet_size, max_packet_size, 64, 512, 10000, 100, broker_config,
  ).unwrap()
  serve_once(listener, config, @router.BrokerState::new(broker_config))
}
