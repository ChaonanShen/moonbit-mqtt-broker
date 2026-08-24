///|
test "Principal storage values round trip without ambiguity" {
  for
    principal in [
      Principal::Anonymous,
      Principal::User("sensor01"),
      Principal::LegacyAnonymous,
    ] {
    assert_eq(
      Principal::from_storage_value(principal.storage_value()),
      Some(principal),
    )
  }
  assert_eq(Principal::from_storage_value(""), None)
  assert_eq(Principal::from_storage_value("user:"), None)
}

///|
test "ACL parser defaults to deny and supports read write and anonymous" {
  let acl = AclPolicy::parse(
    (
      #|user sensor01
      #|topic write devices/sensor01/data
      #|topic read devices/sensor01/command/#
      #|anonymous
      #|topic read public/#
      #|topic readwrite shared/+
      #|
    ),
  ).unwrap()
  assert_true(
    acl.can_write_topic(
      Principal::User("sensor01"),
      @topic.TopicName::new("devices/sensor01/data").unwrap(),
    ),
  )
  assert_false(
    acl.can_write_topic(
      Principal::User("sensor01"),
      @topic.TopicName::new("devices/sensor02/data").unwrap(),
    ),
  )
  assert_true(
    acl.can_read_filter(
      Principal::Anonymous,
      @topic.TopicFilter::new("public/+").unwrap(),
    ),
  )
  assert_false(
    acl.can_read_filter(
      Principal::Anonymous,
      @topic.TopicFilter::new("#").unwrap(),
    ),
  )
}

///|
test "ACL filter containment rejects broader or system-crossing requests" {
  let acl = AclPolicy::parse(
    (
      #|user reader
      #|topic read a/+/c/#
      #|topic read $SYS/broker/#
      #|
    ),
  ).unwrap()
  let principal = Principal::User("reader")
  for allowed in ["a/x/c", "a/+/c", "a/+/c/#", "$SYS/broker/+"] {
    assert_true(
      acl.can_read_filter(principal, @topic.TopicFilter::new(allowed).unwrap()),
    )
  }
  for denied in ["a/#", "a/+/+/#", "#", "$SYS/#", "+/broker/#"] {
    assert_false(
      acl.can_read_filter(principal, @topic.TopicFilter::new(denied).unwrap()),
    )
  }
}

///|
test "ACL always denies client writes to the system namespace" {
  let acl = AclPolicy::parse(
    (
      #|user admin
      #|topic write #
      #|topic write $SYS/#
      #|
    ),
  ).unwrap()
  assert_false(
    acl.can_write_topic(
      Principal::User("admin"),
      @topic.TopicName::new("$SYS/broker/test").unwrap(),
    ),
  )
}

///|
test "ACL parser rejects malformed policy instead of skipping it" {
  assert_true(
    AclPolicy::parse("topic read a/#") is Err(AclFileError::MissingPrincipal(1)),
  )
  assert_true(
    AclPolicy::parse("user anonymous") is Err(AclFileError::InvalidPrincipal(1)),
  )
  assert_true(
    AclPolicy::parse("user a\ntopic execute a/#")
    is Err(AclFileError::InvalidAccess(2)),
  )
  assert_true(
    AclPolicy::parse("user a\ntopic read a/#/b")
    is Err(AclFileError::InvalidFilter(2)),
  )
}

///|
test "Argon2id password database authenticates without plaintext storage" {
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  let database = PasswordDatabase::parse(
    "# generated fixture\nsensor01:" + encoded + "\n",
  ).unwrap()
  assert_eq(database.user_count(), 1)
  assert_eq(
    database.authenticate("sensor01", b"correct horse"),
    AuthenticationResult::Authenticated(Principal::User("sensor01")),
  )
  assert_eq(
    database.authenticate("sensor01", b"wrong"),
    AuthenticationResult::BadCredentials,
  )
  assert_eq(
    database.authenticate("missing", b"correct horse"),
    AuthenticationResult::BadCredentials,
  )
  assert_eq(
    database.authenticate("sensor01", b"correct horse\x00"),
    AuthenticationResult::BadCredentials,
  )
}

///|
test "password file rejects duplicate plaintext and malformed hashes" {
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  assert_true(
    PasswordDatabase::parse("user:plaintext")
    is Err(PasswordFileError::UnsupportedHash(1)),
  )
  assert_true(
    PasswordDatabase::parse("user:$argon2id$broken")
    is Err(PasswordFileError::InvalidHash(1)),
  )
  assert_true(
    PasswordDatabase::parse("user:" + encoded + "\nuser:" + encoded)
    is Err(PasswordFileError::DuplicateUsername("user")),
  )
  assert_true(
    PasswordDatabase::parse(" leading:" + encoded)
    is Err(PasswordFileError::InvalidLine(1)),
  )
}

///|
test "security policy preserves anonymous compatibility and distinguishes rejection" {
  let permissive = SecurityPolicy::permissive()
  assert_eq(
    permissive.authenticate(None, None),
    ConnectAuthentication::Accepted(Principal::Anonymous),
  )
  assert_eq(
    SecurityPolicy::new(allow_anonymous=false).authenticate(None, None),
    ConnectAuthentication::NotAuthorized,
  )
  assert_eq(
    permissive.authenticate(Some("unknown"), Some(b"secret")),
    ConnectAuthentication::BadCredentials,
  )
  assert_false(
    permissive.can_write_topic(
      Principal::Anonymous,
      @topic.TopicName::new("$SYS/broker/test").unwrap(),
    ),
  )
}
