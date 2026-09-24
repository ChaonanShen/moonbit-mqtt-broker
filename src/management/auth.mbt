///|
pub(all) enum AdminScope {
  Metrics
  Read
  Operator
  ConfigAdmin
} derive(Eq, Debug)

///|
pub(all) enum TokenError {
  CryptoUnavailable
  TokenFileMissing
  TokenFileUnsafe
  TokenFileTooLarge
  InvalidTokenFile
} derive(Eq, Debug)

///|
struct TokenEntry {
  digest : FixedArray[Byte]
  scopes : Array[AdminScope]
}

///|
/// This object intentionally has no Debug, Show, ToJson or Eq implementation.
pub struct TokenDatabase {
  entries : Map[String, TokenEntry]
  dummy : FixedArray[Byte]
}

///|
/// The token identifier may be shown in an authenticated audit record; the
/// raw Bearer token and digest may not.
pub struct AdminPrincipal {
  token_id : String
  scopes : Array[AdminScope]
}

///|
pub fn AdminPrincipal::token_id(self : AdminPrincipal) -> String {
  self.token_id
}

///|
pub fn AdminPrincipal::allows(
  self : AdminPrincipal,
  scope : AdminScope,
) -> Bool {
  self.scopes.contains(scope)
}

///|
fn token_hex_nibble(code : Int) -> Int? {
  if code >= 48 && code <= 57 {
    Some(code - 48)
  } else if code >= 97 && code <= 102 {
    Some(code - 87)
  } else {
    None
  }
}

///|
fn valid_token_id(value : String) -> Bool {
  if value.length() < 1 || value.length() > 32 {
    return false
  }
  for ch in value {
    let code = ch.to_int()
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
fn valid_client_token(value : String) -> String? {
  let parts = value.split(".").to_array()
  if parts.length() != 2 ||
    !valid_token_id(parts[0].to_owned()) ||
    parts[1].length() != 64 {
    return None
  }
  for ch in parts[1] {
    if token_hex_nibble(ch.to_int()) is None {
      return None
    }
  }
  Some(parts[0].to_owned())
}

///|
fn parse_token_digest(value : String) -> FixedArray[Byte]? {
  if value.length() != 64 {
    return None
  }
  let digest : FixedArray[Byte] = FixedArray::make(32, 0)
  for index in 0..<32 {
    let high = token_hex_nibble(value[index * 2].to_int())
    let low = token_hex_nibble(value[index * 2 + 1].to_int())
    match (high, low) {
      (Some(hi), Some(lo)) => digest[index] = (hi * 16 + lo).to_byte()
      _ => return None
    }
  }
  Some(digest)
}

///|
fn parse_scope(value : String) -> AdminScope? {
  match value {
    "metrics" => Some(Metrics)
    "read" => Some(Read)
    "operator" => Some(Operator)
    "config_admin" => Some(ConfigAdmin)
    _ => None
  }
}

///|
/// Trusted in-memory parser; production startup uses load() so the native
/// owner/type/mode/size checks run before this parser.
pub fn TokenDatabase::parse(
  contents : Bytes,
) -> Result[TokenDatabase, TokenError] {
  // Trusted in-memory construction must also leave authentication usable.
  // CLI startup calls load() and checks the file before exposing a database.
  if @management_native.initialize() is Err(_) {
    return Err(CryptoUnavailable)
  }
  if contents.length() > 16384 {
    return Err(TokenFileTooLarge)
  }
  let decoded = @utf8.decode(contents) catch {
    _ => return Err(InvalidTokenFile)
  }
  let normalized = decoded.replace_all(old="\r\n", new="\n")
  let entries : Map[String, TokenEntry] = Map([])
  for line in normalized.split("\n") {
    if line == "" {
      continue
    }
    if line.length() > 256 {
      return Err(InvalidTokenFile)
    }
    for ch in line {
      let code = ch.to_int()
      if code < 33 || code > 126 {
        return Err(InvalidTokenFile)
      }
    }
    let parts = line.split(":").to_array()
    if parts.length() != 3 ||
      !valid_token_id(parts[0].to_owned()) ||
      entries.contains(parts[0].to_owned()) {
      return Err(InvalidTokenFile)
    }
    let digest = match parse_token_digest(parts[1].to_owned()) {
      Some(value) => value
      None => return Err(InvalidTokenFile)
    }
    let scopes : Array[AdminScope] = []
    for raw in parts[2].split(",") {
      let scope = match parse_scope(raw.to_owned()) {
        Some(value) => value
        None => return Err(InvalidTokenFile)
      }
      if scopes.contains(scope) {
        return Err(InvalidTokenFile)
      }
      scopes.push(scope)
    }
    if scopes.is_empty() || entries.length() >= 32 {
      return Err(InvalidTokenFile)
    }
    entries.set(parts[0].to_owned(), { digest, scopes })
  }
  if entries.is_empty() {
    return Err(InvalidTokenFile)
  }
  Ok({ entries, dummy: FixedArray::make(32, 0) })
}

///|
pub fn TokenDatabase::load(path : String) -> Result[TokenDatabase, TokenError] {
  match @management_native.initialize() {
    Err(_) => return Err(CryptoUnavailable)
    Ok(_) => ()
  }
  let contents = match @management_native.read_token_file(path) {
    Ok(value) => value
    Err(@management_native.NativeFailure::TokenFileMissing) =>
      return Err(TokenFileMissing)
    Err(@management_native.NativeFailure::TokenFileTooLarge) =>
      return Err(TokenFileTooLarge)
    Err(_) => return Err(TokenFileUnsafe)
  }
  TokenDatabase::parse(contents)
}

///|
pub fn TokenDatabase::token_count(self : TokenDatabase) -> Int {
  self.entries.length()
}

///|
pub fn TokenDatabase::authenticate(
  self : TokenDatabase,
  bearer : String,
) -> AdminPrincipal? {
  let id = match valid_client_token(bearer) {
    Some(value) => value
    None => return None
  }
  let digest = match
    @management_native.sha256(
      @utf8.encode("moonbit-mqtt-broker/admin/v1:" + bearer),
    ) {
    Ok(value) => value
    Err(_) => return None
  }
  let entry = self.entries.get(id)
  let expected = match entry {
    Some(value) => value.digest
    None => self.dummy
  }
  let valid = @management_native.equal32(digest, expected)
  match entry {
    Some(value) if valid => Some({ token_id: id, scopes: value.scopes })
    _ => None
  }
}

///|
/// Authorize a previously authenticated token identifier for a bounded
/// service-owned query without exposing the secret token or digest.
pub fn TokenDatabase::token_has_scope(
  self : TokenDatabase,
  token_id : String,
  scope : AdminScope,
) -> Bool {
  match self.entries.get(token_id) {
    Some(value) => value.scopes.contains(scope)
    None => false
  }
}
