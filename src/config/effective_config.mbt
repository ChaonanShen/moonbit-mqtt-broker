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
pub(all) struct ListenerRestart {
  id : String
  transport : String
  listen : String
  max_connections : Int
  tls_handshake_timeout_ms : Int
  ws_path : String
  ws_allowed_origins : Array[String]
  ws_require_origin : Bool
  http_upgrade_timeout_ms : Int
  max_http_header_bytes : Int
  max_ws_frame_bytes : Int
  max_ws_message_bytes : Int
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
  listener_topology : Array[ListenerRestart]
} derive(Eq, Debug)

///|
priv struct HotListenerDraft {
  id : String
  mut transport : String
  mut listen : String
  mut max_connections : Int
  mut cert : String
  mut key : String
  mut tls_handshake_timeout_ms : Int
  mut ws_path : String
  ws_allowed_origins : Array[String]
  mut ws_require_origin : Bool
  mut http_upgrade_timeout_ms : Int
  mut max_http_header_bytes : Int
  mut max_ws_frame_bytes : Int
  mut max_ws_message_bytes : Int
  mut ws_settings_used : Bool
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
  let mut legacy_listen = "127.0.0.1:1883"
  let mut legacy_tls_timeout = 10000
  let mut global_max_connections = 128
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
      "--tls-handshake-timeout-ms" =>
        legacy_tls_timeout = hot_positive_int(value, option)
      "--listen" => legacy_listen = hot_path(value, option)
      "--max-connections" =>
        global_max_connections = hot_positive_int(value, option)
      "--listener-id" => {
        if value == "" || listeners.any(item => item.id == value) {
          raise EffectiveConfigError("invalid or duplicate listener id")
        }
        listeners.push({
          id: value,
          transport: "",
          listen: "",
          max_connections: -1,
          cert: "",
          key: "",
          tls_handshake_timeout_ms: 10000,
          ws_path: "/mqtt",
          ws_allowed_origins: [],
          ws_require_origin: false,
          http_upgrade_timeout_ms: 5000,
          max_http_header_bytes: 16384,
          max_ws_frame_bytes: 1048576,
          max_ws_message_bytes: 4194304,
          ws_settings_used: false,
        })
      }
      "--listener-transport"
      | "--listener-listen"
      | "--listener-max-connections"
      | "--listener-tls-cert"
      | "--listener-tls-key"
      | "--listener-tls-handshake-timeout-ms"
      | "--listener-ws-path"
      | "--listener-ws-allowed-origin"
      | "--listener-ws-require-origin"
      | "--listener-http-upgrade-timeout-ms"
      | "--listener-max-http-header-bytes"
      | "--listener-max-ws-frame-bytes"
      | "--listener-max-ws-message-bytes" => {
        if listeners.is_empty() {
          raise EffectiveConfigError(option + " needs listener id")
        }
        let draft = listeners[listeners.length() - 1]
        match option {
          "--listener-transport" => draft.transport = value
          "--listener-listen" => draft.listen = hot_path(value, option)
          "--listener-max-connections" =>
            draft.max_connections = hot_positive_int(value, option)
          "--listener-tls-cert" => draft.cert = hot_path(value, option)
          "--listener-tls-key" => draft.key = hot_path(value, option)
          "--listener-tls-handshake-timeout-ms" =>
            draft.tls_handshake_timeout_ms = hot_positive_int(value, option)
          "--listener-ws-path" => {
            draft.ws_path = value
            draft.ws_settings_used = true
          }
          "--listener-ws-allowed-origin" => {
            draft.ws_allowed_origins.push(value)
            draft.ws_settings_used = true
          }
          "--listener-ws-require-origin" => {
            draft.ws_require_origin = hot_bool(value, option)
            draft.ws_settings_used = true
          }
          "--listener-http-upgrade-timeout-ms" => {
            draft.http_upgrade_timeout_ms = hot_positive_int(value, option)
            draft.ws_settings_used = true
          }
          "--listener-max-http-header-bytes" => {
            draft.max_http_header_bytes = hot_positive_int(value, option)
            draft.ws_settings_used = true
          }
          "--listener-max-ws-frame-bytes" => {
            draft.max_ws_frame_bytes = hot_positive_int(value, option)
            draft.ws_settings_used = true
          }
          _ => {
            draft.max_ws_message_bytes = hot_positive_int(value, option)
            draft.ws_settings_used = true
          }
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
  let listener_topology : Array[ListenerRestart] = []
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
    listener_topology.push({
      id: "mqtt",
      transport: if legacy_cert == "" {
        "tcp"
      } else {
        "tls"
      },
      listen: legacy_listen,
      max_connections: global_max_connections,
      tls_handshake_timeout_ms: legacy_tls_timeout,
      ws_path: "/mqtt",
      ws_allowed_origins: [],
      ws_require_origin: false,
      http_upgrade_timeout_ms: 5000,
      max_http_header_bytes: 16384,
      max_ws_frame_bytes: 1048576,
      max_ws_message_bytes: 4194304,
    })
  } else {
    if legacy_cert != "" || legacy_key != "" {
      raise EffectiveConfigError("named listeners cannot use legacy TLS")
    }
    for listener in listeners {
      if listener.listen == "" ||
        !["tcp", "tls", "ws", "wss"].contains(listener.transport) {
        raise EffectiveConfigError("invalid listener topology")
      }
      let cap = if listener.max_connections < 0 {
        global_max_connections
      } else {
        listener.max_connections
      }
      if cap > global_max_connections {
        raise EffectiveConfigError("listener capacity exceeds global cap")
      }
      let needs_tls = listener.transport == "tls" || listener.transport == "wss"
      let needs_ws = listener.transport == "ws" || listener.transport == "wss"
      if !needs_ws && listener.ws_settings_used {
        raise EffectiveConfigError("non-WS listener has WS settings")
      }
      if needs_tls {
        if listener.cert == "" || listener.key == "" {
          raise EffectiveConfigError("TLS listener requires cert and key")
        }
        tls_sources.push({
          listener_id: listener.id,
          cert_path: listener.cert,
          key_path: listener.key,
        })
      } else if listener.cert != "" ||
        listener.key != "" ||
        listener.tls_handshake_timeout_ms != 10000 {
        raise EffectiveConfigError("non-TLS listener has TLS material")
      }
      listener_topology.push({
        id: listener.id,
        transport: listener.transport,
        listen: listener.listen,
        max_connections: cap,
        tls_handshake_timeout_ms: listener.tls_handshake_timeout_ms,
        ws_path: listener.ws_path,
        ws_allowed_origins: listener.ws_allowed_origins.copy(),
        ws_require_origin: listener.ws_require_origin,
        http_upgrade_timeout_ms: listener.http_upgrade_timeout_ms,
        max_http_header_bytes: listener.max_http_header_bytes,
        max_ws_frame_bytes: listener.max_ws_frame_bytes,
        max_ws_message_bytes: listener.max_ws_message_bytes,
      })
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
    listener_topology,
  }
}

///|
pub fn HotConfig::same_listener_topology(
  self : HotConfig,
  other : HotConfig,
) -> Bool {
  if self.listener_topology.length() != other.listener_topology.length() {
    return false
  }
  let by_id : Map[String, ListenerRestart] = Map([])
  for listener in other.listener_topology {
    by_id.set(listener.id, listener)
  }
  for listener in self.listener_topology {
    if by_id.get(listener.id) != Some(listener) {
      return false
    }
  }
  true
}
