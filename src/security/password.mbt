///|
pub(all) enum PasswordFileError {
  InvalidLine(Int)
  InvalidUsername(Int)
  DuplicateUsername(String)
  UnsupportedHash(Int)
  InvalidHash(Int)
  HashCostExceeded(Int)
  Argon2Unavailable
} derive(Eq, Debug)

///|
pub(all) enum AuthenticationResult {
  Authenticated(Principal)
  BadCredentials
} derive(Eq, Debug)

///|
struct PasswordHash {
  encoded : String
  workspace_cost : Int64
}

///|
pub struct PasswordDatabase {
  hashes : Map[String, PasswordHash]
  fallback_hash : PasswordHash?
}

///|
priv enum PasswordHashCost {
  Valid(Int64)
  Invalid
  Exceeded
}

///|
const MAX_ARGON2_MEMORY_KIB : Int64 = 65536L

///|
const MAX_ARGON2_ITERATIONS : Int64 = 10L

///|
const MAX_ARGON2_PARALLELISM : Int64 = 4L

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
  let hashes : Map[String, PasswordHash] = Map([])
  let mut fallback_hash : PasswordHash? = None
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
    let workspace_cost = match password_hash_cost(encoded) {
      Valid(value) => value
      Invalid => return Err(InvalidHash(index + 1))
      Exceeded => return Err(HashCostExceeded(index + 1))
    }
    let status = verify_argon2id(encoded, b"")
    if status == -1000 {
      return Err(Argon2Unavailable)
    }
    // libargon2 returns -35 when a well-formed hash does not match.
    if status != 0 && status != -35 {
      return Err(InvalidHash(index + 1))
    }
    let entry : PasswordHash = { encoded, workspace_cost }
    hashes.set(username, entry)
    if fallback_hash is None {
      fallback_hash = Some(entry)
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
  match self.prepare_password(username, password) {
    None => BadCredentials
    Some(request) => request.complete(request.verify_sync())
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
fn password_hash_cost(encoded : String) -> PasswordHashCost {
  let mut memory : Int64? = None
  let mut iterations : Int64? = None
  let mut parallelism : Int64? = None
  for section in encoded.split("$") {
    if section.has_prefix("m=") {
      for field in section.split(",") {
        if field.has_prefix("m=") {
          memory = phc_number(field.to_owned(), "m=")
        }
        if field.has_prefix("t=") {
          iterations = phc_number(field.to_owned(), "t=")
        }
        if field.has_prefix("p=") {
          parallelism = phc_number(field.to_owned(), "p=")
        }
      }
    }
  }
  match (memory, iterations, parallelism) {
    (Some(m), Some(t), Some(p)) => {
      if m < 1L || t < 1L || p < 1L {
        return Invalid
      }
      if m > MAX_ARGON2_MEMORY_KIB ||
        t > MAX_ARGON2_ITERATIONS ||
        p > MAX_ARGON2_PARALLELISM {
        return Exceeded
      }
      match (@budget.checked_mul(m, 1024L), @budget.checked_mul(p, 262144L)) {
        (Ok(arena), Ok(stacks)) =>
          match @budget.checked_add(arena, stacks) {
            Ok(cost) =>
              match @budget.checked_add(cost, 1048576L) {
                Ok(value) => Valid(value)
                Err(_) => Exceeded
              }
            Err(_) => Exceeded
          }
        _ => Exceeded
      }
    }
    _ => Invalid
  }
}

///|
/// Returns request/workspace logical costs only; never exports the selected PHC.
/// Input hashes were validated at startup. A negative workspace fails admission.
pub fn PasswordDatabase::verification_cost(
  self : PasswordDatabase,
  username : String,
  password_bytes : Int64,
) -> (Int64, Int64) {
  let entry = match self.hashes.get(username) {
    Some(value) => Some(value)
    None => self.fallback_hash
  }
  if entry is None {
    return (128L + password_bytes, 0L)
  }
  let value = entry.unwrap()
  let encoded_bytes = @budget.utf8_bytes(value.encoded)
  let request = match @budget.checked_mul(encoded_bytes, 2L) {
    Ok(copies) =>
      match @budget.checked_add(copies, password_bytes) {
        Ok(input) => @budget.checked_add(input, 128L).unwrap_or(-1L)
        Err(_) => -1L
      }
    Err(_) => -1L
  }
  (request, value.workspace_cost)
}

///|
/// Trusted, secret-free metadata retained while native verification runs.
pub struct AuthenticationCandidate {
  username : String
  known_user : Bool
  request_cost : Int64
  workspace_cost : Int64
}

///|
/// Opaque, short-lived input for the native authentication executor. It does
/// not implement Debug so credentials and PHC data cannot be logged by accident.
pub struct PasswordAuthentication {
  entry : PasswordHash
  password : Bytes
  candidate : AuthenticationCandidate
}

///|
fn password_request_cost(entry : PasswordHash, password_bytes : Int64) -> Int64 {
  let encoded_bytes = @budget.utf8_bytes(entry.encoded)
  match @budget.checked_mul(encoded_bytes, 2L) {
    Ok(copies) =>
      match @budget.checked_add(copies, password_bytes) {
        Ok(input) => @budget.checked_add(input, 128L).unwrap_or(-1L)
        Err(_) => -1L
      }
    Err(_) => -1L
  }
}

///|
pub fn PasswordDatabase::prepare_password(
  self : PasswordDatabase,
  username : String,
  password : Bytes,
) -> PasswordAuthentication? {
  let selected = match self.hashes.get(username) {
    Some(entry) => Some((entry, true))
    None => self.fallback_hash.map(entry => (entry, false))
  }
  match selected {
    None => None
    Some((entry, known_user)) => {
      let candidate : AuthenticationCandidate = {
        username,
        known_user,
        request_cost: password_request_cost(entry, password.length().to_int64()),
        workspace_cost: entry.workspace_cost,
      }
      Some({ entry, password, candidate })
    }
  }
}

///|
pub fn PasswordAuthentication::candidate(
  self : PasswordAuthentication,
) -> AuthenticationCandidate {
  self.candidate
}

///|
pub fn PasswordAuthentication::request_cost(
  self : PasswordAuthentication,
) -> Int64 {
  self.candidate.request_cost
}

///|
pub fn PasswordAuthentication::workspace_cost(
  self : PasswordAuthentication,
) -> Int64 {
  self.candidate.workspace_cost
}

///|
pub fn AuthenticationCandidate::request_cost(
  self : AuthenticationCandidate,
) -> Int64 {
  self.request_cost
}

///|
pub fn AuthenticationCandidate::workspace_cost(
  self : AuthenticationCandidate,
) -> Int64 {
  self.workspace_cost
}

///|
pub fn AuthenticationCandidate::complete(
  self : AuthenticationCandidate,
  matched : Bool,
) -> AuthenticationResult {
  if matched && self.known_user {
    Authenticated(User(self.username))
  } else {
    BadCredentials
  }
}

///|
pub fn PasswordAuthentication::complete(
  self : PasswordAuthentication,
  matched : Bool,
) -> AuthenticationResult {
  self.candidate.complete(matched)
}

///|
fn PasswordAuthentication::verify_sync(self : PasswordAuthentication) -> Bool {
  verify_argon2id(self.entry.encoded, self.password) == 0
}
