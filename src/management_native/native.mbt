///|
pub(all) enum NativeFailure {
  CryptoUnavailable
  InvalidInput
  EntropyUnavailable
  UnsafeTokenFile
  TokenFileTooLarge
  TokenFileMissing
} derive(Eq, Debug)

///|
extern "C" fn ffi_crypto_initialize() -> Int = "moonbit_mqtt_management_crypto_initialize"

///|
#borrow(input, output)
extern "C" fn ffi_hash_token(
  input : Bytes,
  input_length : Int,
  output : FixedArray[Byte],
  output_length : Int,
) -> Int = "moonbit_mqtt_management_hash_token"

///|
#borrow(left, right)
extern "C" fn ffi_constant_time_equal32(
  left : FixedArray[Byte],
  left_length : Int,
  right : FixedArray[Byte],
  right_length : Int,
) -> Int = "moonbit_mqtt_management_constant_time_equal32"

///|
#borrow(output)
extern "C" fn ffi_secure_random(output : FixedArray[Byte], length : Int) -> Int = "moonbit_mqtt_management_secure_random"

///|
#borrow(path, out)
extern "C" fn ffi_read_token_file(
  path : Bytes,
  path_length : Int,
  out : FixedArray[Byte],
  out_capacity : Int,
) -> Int = "moonbit_mqtt_management_read_token_file"

///|
/// Must be called only for management-enabled startup. The dlopen handle is
/// intentionally retained until process exit; no active FFI caller can race a
/// dlclose during shutdown.
pub fn initialize() -> Result[Unit, NativeFailure] {
  if ffi_crypto_initialize() == 0 {
    Ok(())
  } else {
    Err(CryptoUnavailable)
  }
}

///|
pub fn sha256(input : Bytes) -> Result[FixedArray[Byte], NativeFailure] {
  if input.length() > 128 {
    return Err(InvalidInput)
  }
  let output : FixedArray[Byte] = FixedArray::make(32, 0)
  match ffi_hash_token(input, input.length(), output, output.length()) {
    0 => Ok(output)
    -1000 => Err(CryptoUnavailable)
    _ => Err(InvalidInput)
  }
}

///|
pub fn equal32(left : FixedArray[Byte], right : FixedArray[Byte]) -> Bool {
  ffi_constant_time_equal32(left, left.length(), right, right.length()) == 1
}

///|
pub fn secure_random(length : Int) -> Result[FixedArray[Byte], NativeFailure] {
  if length < 1 || length > 32 {
    return Err(InvalidInput)
  }
  let output : FixedArray[Byte] = FixedArray::make(length, 0)
  match ffi_secure_random(output, length) {
    0 => Ok(output)
    -10 | -11 => Err(EntropyUnavailable)
    _ => Err(InvalidInput)
  }
}

///|
pub fn read_token_file(path : String) -> Result[Bytes, NativeFailure] {
  let path_bytes = @utf8.encode(path)
  if path_bytes.length() < 1 || path_bytes.length() > 4096 {
    return Err(InvalidInput)
  }
  let out : FixedArray[Byte] = FixedArray::make(16385, 0)
  let rc = ffi_read_token_file(
    path_bytes,
    path_bytes.length(),
    out,
    out.length(),
  )
  if rc < 0 {
    return match rc {
      -22 => Err(TokenFileMissing)
      -28 => Err(TokenFileTooLarge)
      -20 => Err(InvalidInput)
      _ => Err(UnsafeTokenFile)
    }
  }
  if rc > 16384 {
    return Err(TokenFileTooLarge)
  }
  let bytes : Array[Byte] = []
  for index in 0..<rc {
    bytes.push(out[index])
  }
  Ok(Bytes::from_array(bytes))
}
