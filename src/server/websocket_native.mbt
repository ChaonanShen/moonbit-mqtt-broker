///|
extern "C" fn websocket_crypto_initialize() -> Int = "moonbit_mqtt_websocket_crypto_initialize"

///|
#borrow(key, output)
extern "C" fn websocket_accept_ffi(
  key : Bytes,
  key_length : Int,
  output : FixedArray[Byte],
  output_length : Int,
) -> Int = "moonbit_mqtt_websocket_accept"

///|
pub fn websocket_accept(key : String) -> String? {
  let bytes = @utf8.encode(key)
  let output : FixedArray[Byte] = FixedArray::make(28, 0)
  if websocket_accept_ffi(bytes, bytes.length(), output, 28) != 0 {
    return None
  }
  let result : Array[Byte] = []
  for byte in output {
    result.push(byte)
  }
  Some(@utf8.decode(Bytes::from_array(result)) catch { _ => return None })
}

///|
pub fn websocket_crypto_ready() -> Bool {
  websocket_crypto_initialize() == 0
}
