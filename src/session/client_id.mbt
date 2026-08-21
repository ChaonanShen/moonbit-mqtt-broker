///|
pub(all) enum SessionError {
  EmptyClientId
  EncodedLengthExceeded(Int)
  NullCharacter
} derive(Eq, Debug)

///|
pub struct ClientId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn ClientId::new(value : String) -> Result[ClientId, SessionError] {
  let bytes = @utf8.encode(value)
  if bytes.length() == 0 {
    return Err(EmptyClientId)
  }
  if bytes.length() > 65535 {
    return Err(EncodedLengthExceeded(bytes.length()))
  }
  for byte in bytes {
    if byte.to_int() == 0 {
      return Err(NullCharacter)
    }
  }
  Ok({ value, })
}

///|
pub fn ClientId::value(self : ClientId) -> String {
  self.value
}
