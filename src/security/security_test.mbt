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
fn password_database_fixture(contents : String) -> PasswordDatabase raise {
  match PasswordDatabase::parse(contents) {
    Ok(database) => database
    Err(Argon2Unavailable) =>
      fail(
        "Argon2id tests require libargon2.so.1: install libargon2-1 on Ubuntu/Debian or use scripts/moon-docker.sh test --target native",
      )
    Err(_) =>
      fail(
        "invalid Argon2id test fixture: run scripts/check-argon2.sh to check the reference hash",
      )
  }
}

///|
test "Argon2id password database authenticates without plaintext storage" {
  // Reference checked by scripts/check-argon2.sh (password: correct horse).
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  let database = password_database_fixture(
    "# generated fixture\nsensor01:" + encoded + "\n",
  )
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
  ignore(password_database_fixture("fixture:" + encoded))
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

///|
test "password hashes reject NUL suffixes and non-ASCII before C verification" {
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  for suffix in ["\u0000", "\u0000ignored", "é", "\tignored"] {
    assert_true(
      PasswordDatabase::parse("user:" + encoded + suffix)
      is Err(PasswordFileError::InvalidHash(1)),
    )
  }
}

///|
test "password hash cost limits are checked before native verification" {
  let salt = "MDEyMzQ1Njc4OWFiY2RlZg"
  let digest = "L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  for parameters in ["m=65537,t=2,p=1", "m=4096,t=11,p=1", "m=4096,t=2,p=5"] {
    let oversized = "$argon2id$v=19$" + parameters + "$" + salt + "$" + digest
    assert_true(
      PasswordDatabase::parse("user:" + oversized)
      is Err(PasswordFileError::HashCostExceeded(1)),
    )
  }
  let overflow = "$argon2id$v=19$m=9223372036854775808,t=2,p=1$" +
    salt +
    "$" +
    digest
  assert_true(
    PasswordDatabase::parse("user:" + overflow)
    is Err(PasswordFileError::InvalidHash(1)),
  )
}

///|
test "password database caches verified workspace cost" {
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  let database = password_database_fixture("sensor01:" + encoded)
  let (_, workspace) = database.verification_cost("sensor01", 12L)
  assert_eq(workspace, 5505024L)
  let (_, fallback_workspace) = database.verification_cost("missing", 12L)
  assert_eq(fallback_workspace, workspace)
}

///|
test "password preparation resolves trusted identity without hashing" {
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  let database = password_database_fixture("sensor01:" + encoded)
  let known = database.prepare_password("sensor01", b"not verified").unwrap()
  assert_eq(
    known.complete(true),
    AuthenticationResult::Authenticated(Principal::User("sensor01")),
  )
  assert_eq(known.complete(false), AuthenticationResult::BadCredentials)
  assert_true(known.request_cost() > 128L)
  assert_eq(known.workspace_cost(), 5505024L)
  let unknown = database.prepare_password("missing", b"not verified").unwrap()
  assert_eq(unknown.complete(true), AuthenticationResult::BadCredentials)
}

///|
test "security policy classifies immediate and hash-required authentication" {
  assert_true(
    SecurityPolicy::permissive().prepare_authentication(None, None)
    is AuthenticationPreparation::Immediate(
      ConnectAuthentication::Accepted(Principal::Anonymous)
    ),
  )
  assert_true(
    SecurityPolicy::new(allow_anonymous=false).prepare_authentication(
      None,
      None,
    )
    is AuthenticationPreparation::Immediate(
      ConnectAuthentication::NotAuthorized
    ),
  )
  assert_true(
    SecurityPolicy::permissive().prepare_authentication(Some("user"), None)
    is AuthenticationPreparation::Immediate(
      ConnectAuthentication::BadCredentials
    ),
  )
  let encoded = "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM"
  let passwords = password_database_fixture("sensor01:" + encoded)
  let policy = SecurityPolicy::new(passwords~)
  match policy.prepare_authentication(Some("sensor01"), Some(b"deferred")) {
    HashRequired(request) =>
      assert_eq(
        request.complete_connect(true),
        ConnectAuthentication::Accepted(Principal::User("sensor01")),
      )
    Immediate(_) => fail("password-backed authentication must require hashing")
  }
}
