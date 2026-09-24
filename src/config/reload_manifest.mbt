///|
pub(all) suberror ReloadManifestError {
  ReloadManifestError(String)
} derive(Eq, Debug)

///|
pub(all) struct ReloadMaterial {
  role : String
  listener_id : String?
  path : String
  sha256 : Bytes
} derive(Eq, Debug)

///|
pub(all) struct ReloadManifest {
  materials : Array[ReloadMaterial]
} derive(Eq, Debug)

///|
fn manifest_string(
  table : Map[String, @toml.TomlValue],
  key : String,
) -> String raise ReloadManifestError {
  match table.get(key) {
    Some(TomlString(value)) => value
    _ => raise ReloadManifestError(key + " must be a string")
  }
}

///|
fn hex_digit(value : UInt16) -> Int {
  let code = value.to_int()
  if code >= 48 && code <= 57 {
    code - 48
  } else if code >= 97 && code <= 102 {
    code - 87
  } else {
    -1
  }
}

///|
fn parse_digest(value : String) -> Bytes raise ReloadManifestError {
  if value.length() != 64 {
    raise ReloadManifestError(
      "sha256 must have 64 lowercase hexadecimal digits",
    )
  }
  let bytes : Array[Byte] = []
  for index in 0..<32 {
    let first = hex_digit(value[index * 2])
    let low = hex_digit(value[index * 2 + 1])
    if first < 0 || low < 0 {
      raise ReloadManifestError(
        "sha256 must have 64 lowercase hexadecimal digits",
      )
    }
    bytes.push(((first << 4) | low).to_byte())
  }
  Bytes::from_array(bytes)
}

///|
fn valid_listener_id(value : String) -> Bool {
  if value.length() < 1 || value.length() > 64 {
    return false
  }
  for char in value {
    let code = char.to_int()
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
fn valid_absolute_path(value : String) -> Bool {
  if !value.has_prefix("/") || value.length() < 2 || value.length() > 4096 {
    return false
  }
  for segment in value.split("/") {
    if segment == "." || segment == ".." {
      return false
    }
  }
  !value.contains("//") && !value.contains("\u0000")
}

///|
/// Parses role/path/digest declarations only. The caller still verifies that
/// every effective-config role appears exactly once and captures all files
/// through the bounded native reader before accepting a generation.
pub fn parse_reload_manifest(
  contents : String,
) -> ReloadManifest raise ReloadManifestError {
  let document = @toml.parse(contents) catch {
    _ => raise ReloadManifestError("invalid TOML manifest")
  }
  if !document.validate() {
    raise ReloadManifestError("invalid TOML manifest")
  }
  let root = match document {
    TomlTable(value) => value
    _ => raise ReloadManifestError("manifest root must be a table")
  }
  for key, _ in root {
    if key != "version" && key != "materials" {
      raise ReloadManifestError("unknown manifest key")
    }
  }
  match root.get("version") {
    Some(TomlInteger(1)) => ()
    _ => raise ReloadManifestError("unsupported manifest version")
  }
  let entries = match root.get("materials") {
    Some(TomlArray(value)) => value
    _ => raise ReloadManifestError("materials must be an array of tables")
  }
  if entries.length() < 1 || entries.length() > 35 {
    raise ReloadManifestError("materials count must be in 1..35")
  }
  let materials : Array[ReloadMaterial] = []
  let seen : Map[String, Bool] = Map([])
  let mut config_count = 0
  for entry in entries {
    let table = match entry {
      TomlTable(value) => value
      _ => raise ReloadManifestError("materials entries must be tables")
    }
    for key, _ in table {
      if key != "role" &&
        key != "listener_id" &&
        key != "path" &&
        key != "sha256" {
        raise ReloadManifestError("unknown material key")
      }
    }
    let role = manifest_string(table, "role")
    let listener_id = match table.get("listener_id") {
      None => None
      Some(TomlString(value)) => Some(value)
      _ => raise ReloadManifestError("listener_id must be a string")
    }
    let is_listener = role == "mqtt_cert" || role == "mqtt_key"
    if is_listener {
      match listener_id {
        Some(id) =>
          if !valid_listener_id(id) {
            raise ReloadManifestError("TLS material requires valid listener_id")
          }
        None =>
          raise ReloadManifestError("TLS material requires valid listener_id")
      }
    } else if listener_id is Some(_) {
      raise ReloadManifestError("non-TLS material cannot have listener_id")
    } else if role != "config" && role != "passwords" && role != "acl" {
      raise ReloadManifestError("unknown material role")
    }
    if role == "config" {
      config_count += 1
    }
    let key = role + ":" + listener_id.unwrap_or("")
    if seen.contains(key) {
      raise ReloadManifestError("duplicate material role")
    }
    seen.set(key, true)
    let path = manifest_string(table, "path")
    if !valid_absolute_path(path) {
      raise ReloadManifestError("material path must be absolute and normalized")
    }
    let sha256 = parse_digest(manifest_string(table, "sha256"))
    materials.push({ role, listener_id, path, sha256 })
  }
  if config_count != 1 {
    raise ReloadManifestError("manifest requires exactly one config material")
  }
  { materials, }
}
