///|
fn example_admin_token() -> String {
  "spike-token." +
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}

///|
fn example_admin_digest() -> String {
  "dc211f3214c8dc9ccfdf0c2f2835ed515fc2e032d912934e1d700f8374747236"
}

///|
test "token file parses exact id digest and explicit scopes" {
  let db = TokenDatabase::parse(
    @utf8.encode("spike-token:" + example_admin_digest() + ":metrics,read\n"),
  ).unwrap()
  assert_eq(db.token_count(), 1)
  assert_true(@management_native.initialize() is Ok(_))
  let principal = db.authenticate(example_admin_token()).unwrap()
  assert_eq(principal.token_id(), "spike-token")
  assert_true(principal.allows(Metrics))
  assert_true(principal.allows(Read))
  assert_false(principal.allows(Operator))
  assert_false(principal.allows(ConfigAdmin))
}

///|
test "unknown or altered bearer never acquires a principal" {
  assert_true(@management_native.initialize() is Ok(_))
  let db = TokenDatabase::parse(
    @utf8.encode("spike-token:" + example_admin_digest() + ":metrics\n"),
  ).unwrap()
  assert_true(
    db.authenticate("other-token." + example_admin_token()[12:].to_owned())
    is None,
  )
  assert_true(
    db.authenticate(
      "spike-token." + "f" + example_admin_token()[13:].to_owned(),
    )
    is None,
  )
  assert_true(db.authenticate("spike-token.abc") is None)
  assert_true(
    db.authenticate(
      "spike-token." + "A" + example_admin_token()[13:].to_owned(),
    )
    is None,
  )
  assert_true(db.authenticate("spike-token.") is None)
}

///|
test "token file rejects malformed fields and roles" {
  let digest = example_admin_digest()
  for
    source in [
      "",
      "spike-token:" + digest + ":unknown\n",
      "spike-token:" + digest + ":metrics,metrics\n",
      "spike-token:" + digest + ":metrics,,read\n",
      "spike token:" + digest + ":read\n",
      "spike-token:" + digest + ":read:extra\n",
      "spike-token:" + digest.to_upper() + ":read\n",
      "spike-token:" + digest + ":read\nspike-token:" + digest + ":metrics\n",
      "spike-token:" + digest + ":read\rabc",
    ] {
    assert_true(TokenDatabase::parse(@utf8.encode(source)) is Err(_))
  }
  assert_true(TokenDatabase::parse(Bytes::from_array([0xff, 0xfe])) is Err(_))
}

///|
test "token file accepts bounded role combinations and CRLF" {
  let db = TokenDatabase::parse(
    @utf8.encode(
      "operator-1:" + example_admin_digest() + ":operator,config_admin\r\n",
    ),
  ).unwrap()
  assert_eq(db.token_count(), 1)
  assert_true(
    TokenDatabase::parse(
      @utf8.encode("spike-token:" + example_admin_digest() + ":\n"),
    )
    is Err(_),
  )
}

///|
test "token file enforces count, line, and total bounds" {
  let digest = example_admin_digest()
  let mut contents = ""
  for index in 0..<32 {
    contents = contents + "id" + index.to_string() + ":" + digest + ":read\n"
  }
  assert_eq(
    TokenDatabase::parse(@utf8.encode(contents)).unwrap().token_count(),
    32,
  )
  assert_true(
    TokenDatabase::parse(@utf8.encode(contents + "extra:" + digest + ":read\n"))
    is Err(_),
  )
  assert_true(
    TokenDatabase::parse(
      @utf8.encode("id:" + digest + ":read" + "x".repeat(200)),
    )
    is Err(_),
  )
  assert_true(
    TokenDatabase::parse(Bytes::from_array(Array::make(16385, 65))) is Err(_),
  )
}
