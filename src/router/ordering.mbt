///|
/// Compares Strings by unsigned UTF-8 bytes, independent of locale and maps.
fn compare_utf8(left : String, right : String) -> Int {
  let left_bytes = @utf8.encode(left)
  let right_bytes = @utf8.encode(right)
  let shared = if left_bytes.length() < right_bytes.length() {
    left_bytes.length()
  } else {
    right_bytes.length()
  }
  for index in 0..<shared {
    let difference = left_bytes[index].to_int() - right_bytes[index].to_int()
    if difference != 0 {
      return difference
    }
  }
  left_bytes.length() - right_bytes.length()
}

///|
fn compare_utf8_for_sort(left : String, right : String) -> Int {
  compare_utf8(left, right)
}
