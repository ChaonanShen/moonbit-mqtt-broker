///|
/// A fresh 128-bit boot identity scopes management requests and future
/// operation handles to one process. Failure never falls back to pseudo-random.
pub fn new_boot_id() -> String? {
  let raw = match @management_native.secure_random(16) {
    Ok(value) => value
    Err(_) => return None
  }
  let alphabet = "0123456789abcdef"
  let output : Array[Byte] = []
  for byte in raw {
    let number = byte.to_int()
    output.push(alphabet[number / 16].to_int().to_byte())
    output.push(alphabet[number % 16].to_int().to_byte())
  }
  Some(@utf8.decode(Bytes::from_array(output))) catch {
    _ => None
  }
}
