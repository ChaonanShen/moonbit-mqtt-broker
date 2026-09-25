///|
fn valid_topic_name(value : String, allow_empty : Bool) -> Bool {
  let bytes = @utf8.encode(value)
  if bytes.length() > 65535 || (!allow_empty && bytes.length() == 0) {
    return false
  }
  for byte in bytes {
    if byte.to_int() == 0 || byte.to_int() == 43 || byte.to_int() == 35 {
      return false
    }
  }
  true
}

///|
fn valid_topic_filter(value : String) -> Bool {
  let bytes = @utf8.encode(value)
  if bytes.length() == 0 || bytes.length() > 65535 {
    return false
  }
  let levels = value.split("/").to_array()
  for index in 0..<levels.length() {
    let level = levels[index]
    if level.contains("+") && level != "+" {
      return false
    }
    if level.contains("#") && (level != "#" || index + 1 != levels.length()) {
      return false
    }
  }
  true
}
