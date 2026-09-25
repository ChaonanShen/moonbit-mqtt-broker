///|
test "reload body accepts only bounded single generation field" {
  assert_eq(parse_reload_body(b""), Ok(None))
  assert_eq(parse_reload_body(b"{}"), Ok(None))
  assert_eq(
    parse_reload_body(b" { \"expected_generation\" : 0 } \n"),
    Ok(Some(0L)),
  )
  assert_eq(parse_reload_body(b"{\"expected_generation\":123}"), Ok(Some(123L)))
  for
    invalid in [
      b"{\"expected_generation\":00}", b"{\"expected_generation\":-1}", b"{\"expected_generation\":\"1\"}",
      b"{\"expected_generation\":1.0}", b"{\"unexpected\":1}", b"{\"expected_generation\":1,\"expected_generation\":2}",
      b"{}{}", b"[]",
    ] {
    assert_eq(parse_reload_body(invalid), Err(ReloadBodyInvalid))
  }
  assert_eq(
    parse_reload_body(Bytes::from_array(Array::make(4097, 32))),
    Err(ReloadBodyTooLarge),
  )
}
