///|
#borrow(cert, key, output)
extern "C" fn tls_material_capture_ffi(
  cert : Bytes,
  cert_length : Int,
  key : Bytes,
  key_length : Int,
  output : FixedArray[Byte],
  output_length : Int,
) -> Int = "moonbit_mqtt_tls_material_capture"

///|
#borrow(directory)
extern "C" fn tls_material_release_ffi(directory : Bytes, length : Int) -> Int = "moonbit_mqtt_tls_material_release"

///|
priv struct TlsMaterialLease {
  directory : String
  config : TlsServerConfig
}

///|
fn TlsMaterialLease::capture(
  config : TlsServerConfig,
) -> TlsMaterialLease raise ResourceStartupFailure {
  let cert = @utf8.encode(config.certificate_file())
  let key = @utf8.encode(config.private_key_file())
  let output : FixedArray[Byte] = FixedArray::make(128, 0)
  let rc = tls_material_capture_ffi(
    cert,
    cert.length(),
    key,
    key.length(),
    output,
    output.length(),
  )
  if rc != 0 {
    raise ResourceStartupFailure("TLS material snapshot failed")
  }
  let directory : Array[Byte] = []
  for byte in output {
    if byte == 0 {
      break
    }
    directory.push(byte)
  }
  let path = @utf8.decode(Bytes::from_array(directory)) catch {
    _ => raise ResourceStartupFailure("TLS material path invalid")
  }
  let copy = TlsServerConfig::new(
    path + "/cert.pem",
    path + "/key.pem",
    handshake_timeout_ms=config.handshake_timeout_ms(),
  ).unwrap()
  { directory: path, config: copy }
}

///|
fn TlsMaterialLease::release(self : TlsMaterialLease) -> Unit {
  let path = @utf8.encode(self.directory)
  ignore(tls_material_release_ffi(path, path.length()))
}
