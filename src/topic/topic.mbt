///|
pub(all) enum TopicError {
  EmptyTopicName
  EmptyTopicFilter
  EncodedLengthExceeded(Int)
  NullCharacter
  WildcardInTopicName
  InvalidSingleLevelWildcard
  InvalidMultiLevelWildcard
} derive(Eq, Debug)

///|
pub struct TopicName {
  value : String
} derive(Eq, Hash, Debug)

///|
pub struct TopicFilter {
  value : String
} derive(Eq, Hash, Debug)

///|
fn validate_common(
  value : String,
  empty : TopicError,
) -> Result[Unit, TopicError] {
  let bytes = @utf8.encode(value)
  if bytes.length() == 0 {
    Err(empty)
  } else if bytes.length() > 65535 {
    Err(EncodedLengthExceeded(bytes.length()))
  } else {
    for byte in bytes {
      if byte.to_int() == 0 {
        return Err(NullCharacter)
      }
    }
    Ok(())
  }
}

///|
pub fn TopicName::new(value : String) -> Result[TopicName, TopicError] {
  match validate_common(value, EmptyTopicName) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  for byte in @utf8.encode(value) {
    if byte.to_int() == 43 || byte.to_int() == 35 {
      return Err(WildcardInTopicName)
    }
  }
  Ok({ value, })
}

///|
pub fn TopicName::value(self : TopicName) -> String {
  self.value
}

///|
pub fn TopicFilter::new(value : String) -> Result[TopicFilter, TopicError] {
  match validate_common(value, EmptyTopicFilter) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let levels = value.split("/").to_array()
  for index in 0..<levels.length() {
    let level = levels[index]
    if level.contains("+") && level != "+" {
      return Err(InvalidSingleLevelWildcard)
    }
    if level.contains("#") && (level != "#" || index + 1 != levels.length()) {
      return Err(InvalidMultiLevelWildcard)
    }
  }
  Ok({ value, })
}

///|
pub fn TopicFilter::value(self : TopicFilter) -> String {
  self.value
}
