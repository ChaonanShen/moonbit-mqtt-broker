///|
/// TLS settings for the Broker's single listener.
pub(all) struct TlsServerConfig {
  certificate_file : String
  private_key_file : String
  handshake_timeout_ms : Int
} derive(Debug, Eq)

///|
pub fn TlsServerConfig::new(
  certificate_file : String,
  private_key_file : String,
  handshake_timeout_ms? : Int = 10000,
) -> Result[TlsServerConfig, Unit] {
  guard certificate_file != "" && private_key_file != "" else { Err(()) }
  guard handshake_timeout_ms > 0 else { Err(()) }
  Ok({ certificate_file, private_key_file, handshake_timeout_ms })
}

///|
pub fn TlsServerConfig::certificate_file(self : TlsServerConfig) -> String {
  self.certificate_file
}

///|
pub fn TlsServerConfig::private_key_file(self : TlsServerConfig) -> String {
  self.private_key_file
}

///|
pub fn TlsServerConfig::handshake_timeout_ms(self : TlsServerConfig) -> Int {
  self.handshake_timeout_ms
}

///|
/// Load the PEM material and complete an in-memory handshake before binding
/// the public listener. This rejects unreadable, malformed, expired-for-use,
/// or mismatched certificate/key pairs at startup rather than on first use.
pub async fn validate_tls_config(config : TlsServerConfig) -> Unit {
  @async.with_timeout(config.handshake_timeout_ms(), () => {
    @async.with_task_group() <| group => {
      let (client_reader, server_writer) = @pipe.pipe()
      let (server_reader, client_writer) = @pipe.pipe()
      let server_ready : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      let client_ready : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
      defer {
        server_ready.close(clear=true)
        client_ready.close(clear=true)
        client_reader.close()
        server_writer.close()
        server_reader.close()
        client_writer.close()
      }
      group.spawn_bg() <| () => {
        let server = @tls.Tls::server_from_pair(
          server_reader,
          server_writer,
          private_key_file=config.private_key_file(),
          private_key_type=@tls.PEM,
          certificate_file=config.certificate_file(),
          certificate_type=@tls.PEM,
        )
        server_ready.put(())
        client_ready.get()
        server.close()
      }
      let client = @tls.Tls::client_from_pair(
        client_reader,
        client_writer,
        trust=@tls.NoVerification,
      )
      server_ready.get()
      client_ready.put(())
      client.close()
    }
  })
}
