///|
pub struct RestartScalars {
  values : Map[String, String]
}

///|
fn is_hot_option(option : String) -> Bool {
  [
    "--allow-anonymous", "--password-file", "--acl-file", "--log-format", "--log-level",
    "--system-metrics-interval-ms", "--management-snapshot-interval-ms", "--management-snapshot-max-age-ms",
    "--tls-cert", "--tls-key", "--listen", "--tls-handshake-timeout-ms",
  ].contains(option)
}

///|
fn canonical_restart_option(option : String) -> String {
  match option {
    "--max-pending-qos1-per-session" => "--max-pending-per-session"
    "--max-pending-qos1-total" => "--max-pending-total"
    _ => option
  }
}

///|
fn apply_restart_args(
  values : Map[String, String],
  args : Array[String],
  defaults : Bool,
) -> Unit raise EffectiveConfigError {
  let mut index = 0
  while index < args.length() {
    let option = args[index]
    if option == "--once" {
      values.set("--once", "true")
      index += 1
      continue
    }
    if index + 1 >= args.length() {
      raise EffectiveConfigError(option + " requires a value")
    }
    let value = args[index + 1]
    if !option.has_prefix("--listener-") &&
      !is_hot_option(option) &&
      !(defaults && (option == "--data-dir" || option == "--persistence-mode")) {
      values.set(canonical_restart_option(option), value)
    }
    index += 2
  }
}

///|
/// Normalizes the effective non-listener, restart-only scalar options. TLS
/// paths and other hot fields are excluded. Named listener topology is checked
/// separately before this signature can authorize a reload.
pub fn effective_restart_scalars(
  contents : String,
  cli_args : Array[String],
) -> RestartScalars raise EffectiveConfigError {
  let defaults = parse_config_file(default_effective_config_toml()) catch {
    ConfigFileError(message) => raise EffectiveConfigError(message)
  }
  let from_file = parse_config_file(contents) catch {
    ConfigFileError(message) => raise EffectiveConfigError(message)
  }
  let values : Map[String, String] = Map([])
  values.set("--once", "false")
  apply_restart_args(values, defaults, true)
  let combined = from_file
  combined.append(cli_args)
  apply_restart_args(values, combined, false)
  let data_dir = values.get("--data-dir").unwrap_or("")
  if data_dir == "" {
    values.remove("--data-dir")
  }
  if values.get("--persistence-mode") is None {
    values.set(
      "--persistence-mode",
      if data_dir == "" {
        "off"
      } else {
        "snapshot"
      },
    )
  }
  for
    pair in [
      ("--max-retained-message-bytes", "--max-packet-size"),
      ("--max-will-bytes-per-connection", "--max-packet-size"),
    ] {
    let (derived, source) = pair
    if !combined.contains(derived) {
      values.set(derived, values.get(source).unwrap_or("1048576"))
    }
  }
  { values, }
}

///|
pub fn RestartScalars::same_values(
  self : RestartScalars,
  other : RestartScalars,
) -> Bool {
  if self.values.length() != other.values.length() {
    return false
  }
  for key, value in self.values {
    if other.values.get(key) != Some(value) {
      return false
    }
  }
  true
}
