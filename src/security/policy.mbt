///|
pub(all) enum ConnectAuthentication {
  Accepted(Principal)
  BadCredentials
  NotAuthorized
} derive(Eq, Debug)

///|
pub(all) enum AuthenticationPreparation {
  Immediate(ConnectAuthentication)
  HashRequired(PasswordAuthentication)
}

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
pub fn SecurityPolicy::prepare_authentication(
  self : SecurityPolicy,
  username : String?,
  password : Bytes?,
) -> AuthenticationPreparation {
  match (username, password) {
    (None, None) =>
      Immediate(
        if self.allow_anonymous {
          Accepted(Anonymous)
        } else {
          NotAuthorized
        },
      )
    (Some(user), Some(secret)) =>
      match self.passwords {
        None => Immediate(BadCredentials)
        Some(database) =>
          match database.prepare_password(user, secret) {
            None => Immediate(BadCredentials)
            Some(request) => HashRequired(request)
          }
      }
    _ => Immediate(BadCredentials)
  }
}

///|
pub fn PasswordAuthentication::complete_connect(
  self : PasswordAuthentication,
  matched : Bool,
) -> ConnectAuthentication {
  match self.complete(matched) {
    Authenticated(principal) => Accepted(principal)
    BadCredentials => BadCredentials
  }
}

///|
pub fn SecurityPolicy::authenticate(
  self : SecurityPolicy,
  username : String?,
  password : Bytes?,
) -> ConnectAuthentication {
  match self.prepare_authentication(username, password) {
    Immediate(result) => result
    HashRequired(request) => request.complete_connect(request.verify_sync())
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

///|
pub fn SecurityPolicy::has_passwords(self : SecurityPolicy) -> Bool {
  self.passwords is Some(database) && database.user_count() > 0
}

///|
pub fn SecurityPolicy::authentication_cost(
  self : SecurityPolicy,
  username : String?,
  password : Bytes?,
) -> (Int64, Int64)? {
  match (self.passwords, username, password) {
    (Some(database), Some(user), Some(secret)) if database.user_count() > 0 =>
      Some(database.verification_cost(user, secret.length().to_int64()))
    _ => None
  }
}
