///|
test "MQTT5 protocol config validates negotiated limits" {
  assert_eq(ProtocolConfig::new().unwrap().mqtt5_enabled, false)
  assert_true(ProtocolConfig::new(server_receive_maximum=0) is Err(_))
  assert_true(ProtocolConfig::new(server_keep_alive=65536) is Err(_))
  assert_true(ProtocolConfig::new(topic_alias_maximum=65536) is Err(_))
  assert_true(ProtocolConfig::new(max_user_properties=1025) is Err(_))
  assert_true(ProtocolConfig::new(max_subscription_entries=0) is Err(_))
  assert_true(ProtocolConfig::new(write_timeout_ms=600001) is Err(_))
}

///|
test "MQTT5 TOML uses one protocol option mapping" {
  let args = parse_config_file(
    "[protocol]\nmqtt5_enabled = true\nserver_receive_maximum = 7\nmax_property_bytes = 2048\n",
  )
  assert_true(args.contains("--mqtt5-enabled"))
  assert_true(args.contains("--mqtt5-server-receive-maximum"))
  assert_true(args.contains("--mqtt5-max-property-bytes"))
  let invalid : Result[Array[String], ConfigFileError] = Ok(
    parse_config_file("[protocol]\nmqtt5_enabled = 1\n"),
  ) catch {
    error => Err(error)
  }
  assert_true(invalid is Err(_))
}
