///|
/// The byte transport used by a supervised MQTT connection.
///
/// Keeping socket operations behind this type lets the protocol supervisor
/// remain identical for plain TCP and encrypted connections.
priv enum ConnectionTransport {
  Plain(@socket.Tcp)
  Secure(@tls.Tls, @socket.Tcp)
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
  Secure(encrypted, connection)
}

///|
fn ConnectionTransport::plain(connection : @socket.Tcp) -> ConnectionTransport {
  Plain(connection)
}

///|
async fn ConnectionTransport::read_some(
  self : ConnectionTransport,
  max_len~ : Int,
) -> Bytes? {
  match self {
    Plain(connection) => connection.read_some(max_len~)
    Secure(encrypted, _) => encrypted.read_some(max_len~)
  }
}

///|
async fn ConnectionTransport::write(
  self : ConnectionTransport,
  bytes : Bytes,
) -> Unit {
  match self {
    Plain(connection) => connection.write(bytes)
    Secure(encrypted, _) => encrypted.write(bytes)
  }
}

///|
fn ConnectionTransport::close(self : ConnectionTransport) -> Unit {
  match self {
    Plain(connection) => connection.close()
    Secure(encrypted, connection) => {
      encrypted.close()
      connection.close()
    }
  }
}
