///|
pub(all) enum ConnectAuthentication {
  Accepted(Principal)
  BadCredentials
  NotAuthorized
} derive(Eq, Debug)

///|
/// Immutable startup security policy. Missing ACL means allow application
/// topics for compatibility; `$SYS` remains write-protected.
pub struct SecurityPolicy {
  allow_anonymous : Bool
  passwords : PasswordDatabase?
  acl : AclPolicy?
}

///|
pub fn SecurityPolicy::new(
  allow_anonymous? : Bool = true,
  passwords? : PasswordDatabase,
  acl? : AclPolicy,
) -> SecurityPolicy {
  { allow_anonymous, passwords, acl }
}

///|
pub fn SecurityPolicy::permissive() -> SecurityPolicy {
  SecurityPolicy::new()
}

///|
pub fn SecurityPolicy::authenticate(
  self : SecurityPolicy,
  username : String?,
  password : Bytes?,
) -> ConnectAuthentication {
  match (username, password) {
    (None, None) =>
      if self.allow_anonymous {
        Accepted(Anonymous)
      } else {
        NotAuthorized
      }
    (Some(user), Some(secret)) =>
      match self.passwords {
        None => BadCredentials
        Some(database) =>
          match database.authenticate(user, secret) {
            Authenticated(principal) => Accepted(principal)
            BadCredentials => BadCredentials
          }
      }
    _ => BadCredentials
  }
}

///|
pub fn SecurityPolicy::can_read_filter(
  self : SecurityPolicy,
  principal : Principal,
  filter : @topic.TopicFilter,
) -> Bool {
  match self.acl {
    None => true
    Some(acl) => acl.can_read_filter(principal, filter)
  }
}

///|
pub fn SecurityPolicy::can_read_topic(
  self : SecurityPolicy,
  principal : Principal,
  topic : @topic.TopicName,
) -> Bool {
  match self.acl {
    None => true
    Some(acl) => acl.can_read_topic(principal, topic)
  }
}

///|
pub fn SecurityPolicy::can_write_topic(
  self : SecurityPolicy,
  principal : Principal,
  topic : @topic.TopicName,
) -> Bool {
  if topic.value() == "$SYS" || topic.value().has_prefix("$SYS/") {
    return false
  }
  match self.acl {
    None => true
    Some(acl) => acl.can_write_topic(principal, topic)
  }
}
