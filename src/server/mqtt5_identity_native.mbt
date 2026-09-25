///|
#borrow(output)
extern "C" fn mqtt5_random_16_ffi(
  output : FixedArray[Byte],
  length : Int,
) -> Int = "moonbit_mqtt5_random_16"

///|
fn mqtt5_random_16() -> Bytes? {
  let output : FixedArray[Byte] = FixedArray::make(16, 0)
  if mqtt5_random_16_ffi(output, 16) != 0 {
    return None
  }
  let bytes : Array[Byte] = []
  for byte in output {
    bytes.push(byte)
  }
  Some(Bytes::from_array(bytes))
}

///|
fn mqtt5_hex_digit(value : Int) -> Byte {
  if value < 10 {
    (48 + value).to_byte()
  } else {
    (87 + value).to_byte()
  }
}

///|
pub fn mqtt5_assign_id_with_source(
  source : () -> Bytes?,
  occupied : (String) -> Bool,
) -> String? {
  for _ in 0..<4 {
    let random = match source() {
      Some(value) if value.length() == 16 => value
      _ => return None
    }
    let ascii : Array[Byte] = [109, 98, 53, 45]
    for byte in random {
      let number = byte.to_int()
      ascii.push(mqtt5_hex_digit((number >> 4) & 15))
      ascii.push(mqtt5_hex_digit(number & 15))
    }
    let id = @utf8.decode(Bytes::from_array(ascii)) catch { _ => return None }
    if !occupied(id) {
      return Some(id)
    }
  }
  None
}

///|
pub fn mqtt5_assign_id(occupied : (String) -> Bool) -> String? {
  mqtt5_assign_id_with_source(mqtt5_random_16, occupied)
}
