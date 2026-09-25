///|
pub(all) enum QueryKind {
  Listeners
  Connections
  Connection
  Sessions
  Session
  Subscriptions
  Retained
  Config
  Operation
  Audit
} derive(Eq, Debug)

///|
pub(all) enum QueryError {
  QueryBadRequest
  QueryNotFound
  QueryPreconditionFailed
  QueryExpiredCursor
  QueryForbidden
  QueryDetailsUnavailable
  QueryCapacityExhausted
  QueryResultTooLarge
  QueryUnavailable
} derive(Eq, Debug)

///|
/// A bounded request description, created after HTTP authentication. It
/// contains no bearer token, MQTT payload, mutable broker state, or socket.
pub(all) struct QuerySpec {
  kind : QueryKind
  target : String
  actor_token_id : String
  limit : Int
  cursor : String?
  filters : String
}

///|
pub(all) struct QueryEnvelope {
  boot_id : String
  observed_at_ms : Int64
  state_revision : Int64
  items : Array[Json]
  next_cursor : String?
}

///|
pub fn QueryEnvelope::to_json(self : QueryEnvelope) -> Json {
  let object : Map[String, Json] = Map([
    ("api_version", "1".to_json()),
    ("boot_id", self.boot_id.to_json()),
    ("observed_at_ms", self.observed_at_ms.to_string().to_json()),
    ("state_revision", self.state_revision.to_string().to_json()),
    ("consistency", "per_page".to_json()),
    ("items", self.items.to_json()),
    ("next_cursor", optional_string_json(self.next_cursor)),
  ])
  object.to_json()
}

///|
/// ETags include the boot and identity epoch. Queue contents and other
/// business revisions do not change a Session lifecycle ETag.
pub fn connection_etag(boot_id : String, connection_id : Int64) -> String {
  "\"" + boot_id + ":c:" + connection_id.to_string() + "\""
}

///|
pub fn session_etag(
  boot_id : String,
  handle : Int64,
  lifecycle_version : Int64,
) -> String {
  "\"" +
  boot_id +
  ":s:" +
  handle.to_string() +
  ":" +
  lifecycle_version.to_string() +
  "\""
}

///|
/// A config ETag is boot-scoped and changes only on an effective generation
/// publication. Epoch zero is the validated startup generation.
pub fn config_etag(boot_id : String, config_epoch : Int64) -> String {
  "\"" + boot_id + ":g:" + config_epoch.to_string() + "\""
}

///|
fn canonical_generation(value : String) -> Bool {
  if value == "" || value.length() > 19 {
    return false
  }
  for byte in value {
    if byte.to_int() < 48 || byte.to_int() > 57 {
      return false
    }
  }
  let parsed = @string.parse_int64(value) catch { _ => return false }
  parsed >= 0L && parsed.to_string() == value
}

///|
fn canonical_positive_id(value : String) -> Bool {
  if value == "" || value == "0" || value.length() > 19 {
    return false
  }
  for byte in value {
    if byte.to_int() < 48 || byte.to_int() > 57 {
      return false
    }
  }
  let parsed = @string.parse_int64(value) catch { _ => return false }
  parsed > 0L && parsed.to_string() == value
}

///|
/// Parses only the B read allowlist. Target identities are canonical decimal
/// strings; no URL decoding, client ID, topic, or filter path alias exists.
pub fn parse_read_query(
  target : String,
  actor_token_id : String,
  default_page_size : Int,
  max_page_size : Int,
) -> Result[QuerySpec, QueryError] {
  if target.contains("%") ||
    target.contains("#") ||
    actor_token_id.length() > 32 {
    return Err(QueryBadRequest)
  }
  let parts = target.split("?").to_array()
  if parts.length() > 2 {
    return Err(QueryBadRequest)
  }
  let path = parts[0].to_owned()
  let segments = path.split("/").to_array()
  let mut target_id = ""
  let kind = match path {
    "/v1/listeners" => Listeners
    "/v1/connections" => Connections
    "/v1/sessions" => Sessions
    "/v1/retained" => Retained
    "/v1/audit" => Audit
    "/v1/config" => Config
    _ =>
      if segments.length() == 4 &&
        segments[0] == "" &&
        segments[1] == "v1" &&
        segments[2] == "connections" &&
        canonical_positive_id(segments[3].to_owned()) {
        target_id = segments[3].to_owned()
        Connection
      } else if segments.length() == 4 &&
        segments[0] == "" &&
        segments[1] == "v1" &&
        segments[2] == "sessions" &&
        canonical_positive_id(segments[3].to_owned()) {
        target_id = segments[3].to_owned()
        Session
      } else if segments.length() == 5 &&
        segments[0] == "" &&
        segments[1] == "v1" &&
        segments[2] == "sessions" &&
        canonical_positive_id(segments[3].to_owned()) &&
        segments[4] == "subscriptions" {
        target_id = segments[3].to_owned()
        Subscriptions
      } else {
        return Err(QueryNotFound)
      }
  }
  let mut limit = default_page_size
  let mut cursor : String? = None
  let mut attached : String? = None
  let mut mode : String? = None
  let mut phase : String? = None
  let seen : Map[String, Bool] = Map([])
  if parts.length() == 2 {
    let raw_query = parts[1].to_owned()
    if raw_query == "" {
      return Err(QueryBadRequest)
    }
    for entry in raw_query.split("&") {
      let pair = entry.split("=").to_array()
      if pair.length() != 2 || pair[0] == "" || pair[1] == "" {
        return Err(QueryBadRequest)
      }
      let name = pair[0].to_owned()
      let value = pair[1].to_owned()
      if seen.contains(name) {
        return Err(QueryBadRequest)
      }
      seen.set(name, true)
      match name {
        "limit" =>
          match kind {
            Connections | Sessions | Subscriptions | Retained | Audit => {
              let parsed = @string.parse_int(value) catch {
                _ => return Err(QueryBadRequest)
              }
              if parsed < 1 ||
                parsed > max_page_size ||
                parsed.to_string() != value {
                return Err(QueryBadRequest)
              }
              limit = parsed
            }
            _ => return Err(QueryBadRequest)
          }
        "cursor" =>
          match kind {
            Connections | Sessions | Subscriptions | Retained | Audit => {
              if value.length() != 65 {
                return Err(QueryBadRequest)
              }
              cursor = Some(value)
            }
            _ => return Err(QueryBadRequest)
          }
        "attached" =>
          if kind == Sessions && (value == "true" || value == "false") {
            attached = Some(value)
          } else {
            return Err(QueryBadRequest)
          }
        "mode" =>
          if kind == Sessions && (value == "clean" || value == "persistent") {
            mode = Some(value)
          } else {
            return Err(QueryBadRequest)
          }
        "phase" =>
          if kind == Connections &&
            (
              value == "await_connect" ||
              value == "authenticating" ||
              value == "active"
            ) {
            phase = Some(value)
          } else {
            return Err(QueryBadRequest)
          }
        _ => return Err(QueryBadRequest)
      }
    }
  }
  let mut filters = ""
  if attached is Some(value) {
    filters += "attached=" + value
  }
  if mode is Some(value) {
    if filters != "" {
      filters += "&"
    }
    filters += "mode=" + value
  }
  if phase is Some(value) {
    filters += "phase=" + value
  }
  if filters.length() > 128 {
    return Err(QueryBadRequest)
  }
  Ok({ kind, target: target_id, actor_token_id, limit, cursor, filters })
}

///|
pub fn optional_string_json(value : String?) -> Json {
  match value {
    Some(text) => text.to_json()
    None => @json.to_json(())
  }
}

///|
pub fn optional_decimal_json(value : Int64?) -> Json {
  match value {
    Some(number) => number.to_string().to_json()
    None => @json.to_json(())
  }
}
