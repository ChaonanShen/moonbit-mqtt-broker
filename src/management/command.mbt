///|
pub(all) enum CommandParseError {
  InvalidCommandPath
  InvalidIdempotencyKey
  InvalidIfMatch
} derive(Eq, Debug)

///|
pub(all) struct StrongEtag {
  boot_id : String
  kind : String
  target : Int64
  lifecycle_version : Int64?
} derive(Eq, Debug)

///|
pub(all) struct CommandSpec {
  kind : OperationKind
  target : String
  if_match : String
  idempotency_key : String
  actor_token_id : String
} derive(Eq, Debug)

///|
pub fn valid_idempotency_key(value : String) -> Bool {
  if value.length() < 16 || value.length() > 64 {
    return false
  }
  for byte in value {
    let code = byte.to_int()
    if !((code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 45 ||
      code == 95) {
      return false
    }
  }
  true
}

///|
fn valid_boot_hex(value : String) -> Bool {
  if value.length() != 32 {
    return false
  }
  for byte in value {
    let code = byte.to_int()
    if !((code >= 48 && code <= 57) || (code >= 97 && code <= 102)) {
      return false
    }
  }
  true
}

///|
pub fn parse_strong_etag(
  value : String,
  expected_kind : String,
) -> Result[StrongEtag, CommandParseError] {
  if value.length() < (if expected_kind == "c" { 37 } else { 39 }) ||
    value.length() > 100 ||
    value[0].to_int() != 34 ||
    value[value.length() - 1].to_int() != 34 {
    return Err(InvalidIfMatch)
  }
  let inner = value[1:value.length() - 1].to_owned()
  let parts = inner.split(":").to_array()
  let expected_parts = if expected_kind == "c" { 3 } else { 4 }
  if parts.length() != expected_parts ||
    !valid_boot_hex(parts[0].to_owned()) ||
    parts[1] != expected_kind ||
    !canonical_positive_id(parts[2].to_owned()) {
    return Err(InvalidIfMatch)
  }
  let version = if expected_kind == "s" {
    if !canonical_positive_id(parts[3].to_owned()) {
      return Err(InvalidIfMatch)
    }
    Some(
      @string.parse_int64(parts[3].to_owned()) catch {
        _ => return Err(InvalidIfMatch)
      },
    )
  } else {
    None
  }
  Ok({
    boot_id: parts[0].to_owned(),
    kind: expected_kind,
    target: @string.parse_int64(parts[2].to_owned()) catch {
      _ => return Err(InvalidIfMatch)
    },
    lifecycle_version: version,
  })
}

///|
pub fn parse_command(
  method_name : String,
  path : String,
  if_match : String,
  idempotency_key : String,
  actor_token_id : String,
) -> Result[CommandSpec, CommandParseError] {
  if !valid_idempotency_key(idempotency_key) || actor_token_id.length() > 32 {
    return Err(InvalidIdempotencyKey)
  }
  if path.contains("?") || path.contains("%") || path.contains("#") {
    return Err(InvalidCommandPath)
  }
  let parts = path.split("/").to_array()
  let (kind, target, etag_kind) = if method_name == "POST" &&
    parts.length() == 5 &&
    parts[0] == "" &&
    parts[1] == "v1" &&
    parts[2] == "connections" &&
    canonical_positive_id(parts[3].to_owned()) &&
    parts[4] == "disconnect" {
    (Kick, parts[3].to_owned(), "c")
  } else if method_name == "DELETE" &&
    parts.length() == 4 &&
    parts[0] == "" &&
    parts[1] == "v1" &&
    parts[2] == "sessions" &&
    canonical_positive_id(parts[3].to_owned()) {
    (DeleteSession, parts[3].to_owned(), "s")
  } else {
    return Err(InvalidCommandPath)
  }
  let etag = match parse_strong_etag(if_match, etag_kind) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if etag.target.to_string() != target {
    return Err(InvalidIfMatch)
  }
  Ok({ kind, target, if_match, idempotency_key, actor_token_id })
}

///|
pub fn CommandSpec::normalized(self : CommandSpec) -> String {
  let route = match self.kind {
    Kick => "POST:/v1/connections/"
    DeleteSession => "DELETE:/v1/sessions/"
    Reload => "POST:/v1/config/reload"
  }
  route + self.target + ":" + self.if_match
}
