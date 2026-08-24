///|
/// The authenticated identity bound to a connection and persistent Session.
pub(all) enum Principal {
  Anonymous
  User(String)
  LegacyAnonymous
} derive(Eq, Hash, Debug)

///|
pub fn Principal::storage_value(self : Principal) -> String {
  match self {
    Anonymous => "anonymous"
    User(username) => "user:" + username
    LegacyAnonymous => "legacy-anonymous"
  }
}

///|
pub fn Principal::from_storage_value(value : String) -> Principal? {
  if value == "anonymous" {
    Some(Anonymous)
  } else if value == "legacy-anonymous" {
    Some(LegacyAnonymous)
  } else if value.has_prefix("user:") && value.length() > 5 {
    Some(User(value[5:].to_owned()))
  } else {
    None
  }
}
