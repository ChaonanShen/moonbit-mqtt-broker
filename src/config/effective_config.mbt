///|
pub(all) suberror EffectiveConfigError {
  EffectiveConfigError(String)
} derive(Eq, Debug)

///|
pub(all) struct HotTlsSource {
  listener_id : String
  cert_path : String
  key_path : String
} derive(Eq, Debug)

///|
pub(all) struct HotConfig {
  allow_anonymous : Bool
  password_file : String?
  acl_file : String?
  log_format : String
  log_level : String
  system_metrics_interval_ms : Int
  management_snapshot_interval_ms : Int
  management_snapshot_max_age_ms : Int
  tls_sources : Array[HotTlsSource]
} derive(Eq, Debug)

///|
priv struct HotListenerDraft {
  id : String
  mut transport : String
  mut cert : String
  mut key : String
}

///|
fn hot_bool(value : String, option : String) -> Bool raise EffectiveConfigError {
  match value {
    "true" => true
    "false" => false
    _ => raise EffectiveConfigError("invalid " + option)
  }
}

///|
fn hot_positive_int(
  value : String,
  option : String,
) -> Int raise EffectiveConfigError {
  let result = @string.parse_int(value) catch {
    _ => raise EffectiveConfigError("invalid " + option)
  }
  if result < 1 {
    raise EffectiveConfigError("invalid " + option)
  }
  result
}

///|
fn hot_path(
  value : String,
  option : String,
) -> String raise EffectiveConfigError {
  if value == "" {
    raise EffectiveConfigError(option + " requires a path")
  }
  value
}

///|
/// Recomputes hot settings from defaults, the complete new TOML, and frozen
/// startup CLI overrides. Removing a TOML key restores its effective default.
pub fn effective_hot_config(
  contents : String,
  cli_args : Array[String],
) -> HotConfig raise EffectiveConfigError {
  let file_args = parse_config_file(contents) catch {
    ConfigFileError(message) => raise EffectiveConfigError(message)
  }
  let args = file_args
  args.append(cli_args)
  let mut allow_anonymous = true
  let mut password_file : String? = None
  let mut acl_file : String? = None
  let mut log_format = "text"
  let mut log_level = "info"
  let mut system_metrics_interval_ms = 10000
  let mut management_snapshot_interval_ms = 1000
  let mut management_snapshot_max_age_ms = 5000
  let mut legacy_cert = ""
  let mut legacy_key = ""
  let listeners : Array[HotListenerDraft] = []
  let mut index = 0
  while index < args.length() {
    let option = args[index]
    if option == "--once" {
      index += 1
      continue
    }
    if index + 1 >= args.length() {
      raise EffectiveConfigError(option + " requires a value")
    }
    let value = args[index + 1]
    match option {
      "--allow-anonymous" => allow_anonymous = hot_bool(value, option)
      "--password-file" => password_file = Some(hot_path(value, option))
      "--acl-file" => acl_file = Some(hot_path(value, option))
      "--log-format" =>
        if value == "text" || value == "json" {
          log_format = value
        } else {
          raise EffectiveConfigError("invalid --log-format")
        }
      "--log-level" =>
        if ["error", "warn", "info", "debug"].contains(value) {
          log_level = value
        } else {
          raise EffectiveConfigError("invalid --log-level")
        }
      "--system-metrics-interval-ms" =>
        system_metrics_interval_ms = hot_positive_int(value, option)
      "--management-snapshot-interval-ms" =>
        management_snapshot_interval_ms = hot_positive_int(value, option)
      "--management-snapshot-max-age-ms" =>
        management_snapshot_max_age_ms = hot_positive_int(value, option)
      "--tls-cert" => legacy_cert = hot_path(value, option)
      "--tls-key" => legacy_key = hot_path(value, option)
      "--listener-id" => {
        if value == "" || listeners.any(item => item.id == value) {
          raise EffectiveConfigError("invalid or duplicate listener id")
        }
        listeners.push({ id: value, transport: "", cert: "", key: "" })
      }
      "--listener-transport" | "--listener-tls-cert" | "--listener-tls-key" => {
        if listeners.is_empty() {
          raise EffectiveConfigError(option + " needs listener id")
        }
        let draft = listeners[listeners.length() - 1]
        match option {
          "--listener-transport" => draft.transport = value
          "--listener-tls-cert" => draft.cert = hot_path(value, option)
          _ => draft.key = hot_path(value, option)
        }
      }
      _ => ()
    }
    index += 2
  }
  if !allow_anonymous && password_file is None {
    raise EffectiveConfigError(
      "disabled anonymous authentication requires passwords",
    )
  }
  if management_snapshot_max_age_ms.to_int64() <
    management_snapshot_interval_ms.to_int64() * 3L {
    raise EffectiveConfigError("invalid management snapshot freshness")
  }
  let tls_sources : Array[HotTlsSource] = []
  if listeners.is_empty() {
    if legacy_cert != "" || legacy_key != "" {
      if legacy_cert == "" || legacy_key == "" {
        raise EffectiveConfigError("TLS cert and key must be paired")
      }
      tls_sources.push({
        listener_id: "mqtt",
        cert_path: legacy_cert,
        key_path: legacy_key,
      })
    }
  } else {
    if legacy_cert != "" || legacy_key != "" {
      raise EffectiveConfigError("named listeners cannot use legacy TLS")
    }
    for listener in listeners {
      let needs_tls = listener.transport == "tls" || listener.transport == "wss"
      if needs_tls {
        if listener.cert == "" || listener.key == "" {
          raise EffectiveConfigError("TLS listener requires cert and key")
        }
        tls_sources.push({
          listener_id: listener.id,
          cert_path: listener.cert,
          key_path: listener.key,
        })
      } else if listener.cert != "" || listener.key != "" {
        raise EffectiveConfigError("non-TLS listener has TLS material")
      }
    }
  }
  {
    allow_anonymous,
    password_file,
    acl_file,
    log_format,
    log_level,
    system_metrics_interval_ms,
    management_snapshot_interval_ms,
    management_snapshot_max_age_ms,
    tls_sources,
  }
}
