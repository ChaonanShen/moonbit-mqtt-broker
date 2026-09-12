///|
test "all registered resource keys parse with exact CLI mapping" {
  let specs = @budget.byte_limit_specs()
  specs.append(@budget.rate_limit_specs())
  for spec in specs {
    let (section, key, value) = spec
    let args = parse_config_file(
      "[" + section + "]\n" + key + " = " + value.to_string() + "\n",
    )
    assert_eq(args, [
      "--" + key.replace_all(old="_", new="-"),
      value.to_string(),
    ])
  }
  assert_eq(
    parse_config_file("[limits]\nenabled = false\nper_ip_enabled = false\n"),
    ["--rate-limits-enabled", "false", "--per-ip-limits-enabled", "false"],
  )
}
