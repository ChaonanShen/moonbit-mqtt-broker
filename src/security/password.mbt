///|
pub(all) enum PasswordFileError {
  InvalidLine(Int)
  InvalidUsername(Int)
  DuplicateUsername(String)
  UnsupportedHash(Int)
  InvalidHash(Int)
  Argon2Unavailable
} derive(Eq, Debug)

///|
pub(all) enum AuthenticationResult {
  Authenticated(Principal)
  BadCredentials
} derive(Eq, Debug)

///|
pub struct PasswordDatabase {
  hashes : Map[String, String]
  fallback_hash : String?
}

///|
#borrow(encoded, password)
extern "C" fn verify_argon2id_ffi(
  encoded : String,
  encoded_length : Int,
  password : Bytes,
  password_length : Int,
) -> Int = "moonbit_mqtt_verify_argon2id"

///|
fn verify_argon2id(encoded : String, password : Bytes) -> Int {
  verify_argon2id_ffi(encoded, encoded.length(), password, password.length())
}

///|
pub fn PasswordDatabase::parse(
  contents : String,
) -> Result[PasswordDatabase, PasswordFileError] {
  let hashes : Map[String, String] = Map([])
  let mut fallback_hash : String? = None
  let lines = contents.replace_all(old="\r\n", new="\n").split("\n").to_array()
  for index in 0..<lines.length() {
    let line = lines[index]
    let trimmed = line.trim()
    if trimmed == "" || trimmed.has_prefix("#") {
      continue
    }
    if trimmed != line {
      return Err(InvalidLine(index + 1))
    }
    let fields = line.split(":").to_array()
    if fields.length() != 2 {
      return Err(InvalidLine(index + 1))
    }
    let username = fields[0].to_owned()
    let encoded = fields[1].to_owned()
    if username == "" || username.contains(" ") || username.contains("\t") {
      return Err(InvalidUsername(index + 1))
    }
    if hashes.get(username) is Some(_) {
      return Err(DuplicateUsername(username))
    }
    if !encoded.has_prefix("$argon2id$") {
      return Err(UnsupportedHash(index + 1))
    }
    let status = verify_argon2id(encoded, b"")
    if status == -1000 {
      return Err(Argon2Unavailable)
    }
    // libargon2 returns -35 when a well-formed hash does not match.
    if status != 0 && status != -35 {
      return Err(InvalidHash(index + 1))
    }
    hashes.set(username, encoded)
    if fallback_hash is None {
      fallback_hash = Some(encoded)
    }
  }
  Ok({ hashes, fallback_hash })
}

///|
pub fn PasswordDatabase::user_count(self : PasswordDatabase) -> Int {
  self.hashes.length()
}

///|
pub fn PasswordDatabase::authenticate(
  self : PasswordDatabase,
  username : String,
  password : Bytes,
) -> AuthenticationResult {
  let selected = match self.hashes.get(username) {
    Some(encoded) => Some((encoded, true))
    None => self.fallback_hash.map(encoded => (encoded, false))
  }
  match selected {
    None => BadCredentials
    Some((encoded, known_user)) => {
      let verified = verify_argon2id(encoded, password) == 0
      if verified && known_user {
        Authenticated(User(username))
      } else {
        BadCredentials
      }
    }
  }
}
