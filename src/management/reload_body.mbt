///|
pub(all) enum ReloadBodyError {
  ReloadBodyInvalid
  ReloadBodyTooLarge
} derive(Eq, Debug)

///|
fn reload_skip_ws(value : String, start : Int) -> Int {
  let mut index = start
  while index < value.length() {
    let code = value[index].to_int()
    if code == 32 || code == 9 || code == 10 || code == 13 {
      index += 1
    } else {
      break
    }
  }
  index
}

///|
/// The body is deliberately a one-field JSON subset. Empty body, {} and a
/// canonical nonnegative decimal expected_generation are the only forms.
pub fn parse_reload_body(bytes : Bytes) -> Result[Int64?, ReloadBodyError] {
  if bytes.length() > 4096 {
    return Err(ReloadBodyTooLarge)
  }
  if bytes.length() == 0 {
    return Ok(None)
  }
  let value = @utf8.decode(bytes) catch { _ => return Err(ReloadBodyInvalid) }
  let mut index = reload_skip_ws(value, 0)
  if index >= value.length() || value[index].to_int() != 123 {
    return Err(ReloadBodyInvalid)
  }
  index = reload_skip_ws(value, index + 1)
  if index < value.length() && value[index].to_int() == 125 {
    index = reload_skip_ws(value, index + 1)
    return if index == value.length() {
      Ok(None)
    } else {
      Err(ReloadBodyInvalid)
    }
  }
  let key = "\"expected_generation\""
  if index + key.length() > value.length() ||
    value[index:index + key.length()].to_owned() != key {
    return Err(ReloadBodyInvalid)
  }
  index = reload_skip_ws(value, index + key.length())
  if index >= value.length() || value[index].to_int() != 58 {
    return Err(ReloadBodyInvalid)
  }
  index = reload_skip_ws(value, index + 1)
  let first = index
  while index < value.length() {
    let digit = value[index].to_int()
    if digit < 48 || digit > 57 {
      break
    }
    index += 1
  }
  if index == first || (index - first > 1 && value[first].to_int() == 48) {
    return Err(ReloadBodyInvalid)
  }
  let number = @string.parse_int64(value[first:index].to_owned()) catch {
    _ => return Err(ReloadBodyInvalid)
  }
  if number < 0L {
    return Err(ReloadBodyInvalid)
  }
  index = reload_skip_ws(value, index)
  if index >= value.length() || value[index].to_int() != 125 {
    return Err(ReloadBodyInvalid)
  }
  index = reload_skip_ws(value, index + 1)
  if index != value.length() {
    return Err(ReloadBodyInvalid)
  }
  Ok(Some(number))
}
