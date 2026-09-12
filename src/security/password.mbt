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
  encoded : Bytes,
  encoded_length : Int,
  password : Bytes,
  password_length : Int,
) -> Int = "moonbit_mqtt_verify_argon2id"

///|
fn verify_argon2id(encoded : String, password : Bytes) -> Int {
  let encoded_bytes = @utf8.encode(encoded)
  verify_argon2id_ffi(
    encoded_bytes,
    encoded_bytes.length(),
    password,
    password.length(),
  )
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
    // PHC encoded hashes are printable ASCII. Reject NUL before crossing the
    // C string boundary, and invalid UTF-16 before calling the UTF-8 encoder.
    for unit in encoded.code_units() {
      if unit.to_int() < 33 || unit.to_int() > 126 {
        return Err(InvalidHash(index + 1))
      }
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

///|
fn phc_number(field : String, prefix : String) -> Int64? {
  if !field.has_prefix(prefix) {
    return None
  }
  let digits = field[prefix.length():]
  if digits.is_empty() {
    return None
  }
  let mut number = 0L
  for character in digits {
    let code = character.to_int() - 48
    if code < 0 ||
      code > 9 ||
      number > (9223372036854775807L - code.to_int64()) / 10L {
      return None
    }
    number = number * 10L + code.to_int64()
  }
  Some(number)
}

///|
/// Returns request/workspace logical costs only; never exports the selected PHC.
/// Input hashes were validated at startup. A negative workspace fails admission.
pub fn PasswordDatabase::verification_cost(
  self : PasswordDatabase,
  username : String,
  password_bytes : Int64,
) -> (Int64, Int64) {
  let encoded = match self.hashes.get(username) {
    Some(h) => h
    None => self.fallback_hash.unwrap_or("")
  }
  let mut memory : Int64? = None
  let mut parallelism : Int64? = None
  for section in encoded.split("$") {
    if section.has_prefix("m=") {
      for field in section.split(",") {
        if field.has_prefix("m=") {
          memory = phc_number(field.to_owned(), "m=")
        }
        if field.has_prefix("p=") {
          parallelism = phc_number(field.to_owned(), "p=")
        }
      }
    }
  }
  let request = @budget.utf8_bytes(encoded) * 2L + password_bytes + 128L
  let workspace = match (memory, parallelism) {
    (Some(m), Some(p)) =>
      match (@budget.checked_mul(m, 1024L), @budget.checked_mul(p, 262144L)) {
        (Ok(arena), Ok(stacks)) =>
          match @budget.checked_add(arena, stacks) {
            Ok(cost) =>
              match @budget.checked_add(cost, 1048576L) {
                Ok(n) => n
                Err(_) => -1L
              }
            Err(_) => -1L
          }
        _ => -1L
      }
    _ => -1L
  }
  (request, workspace)
}
