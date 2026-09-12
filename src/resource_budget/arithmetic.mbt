///|
pub(all) enum BudgetError {
  InvalidAmount
  Overflow
  InvalidConfiguration
  Exhausted(LimitScope, Int64, Int64, Int64)
  TicketLimit
  InvalidTicketState
  ForeignAccount
} derive(Eq, Debug)

///|
pub(all) enum LimitScope {
  Global
  Control
  Category
  Session
  Connection
  Ip
} derive(Eq, Debug)

///|
pub fn checked_add(a : Int64, b : Int64) -> Result[Int64, BudgetError] {
  if a < 0L || b < 0L {
    return Err(InvalidAmount)
  }
  if b > 9223372036854775807L - a {
    return Err(Overflow)
  }
  Ok(a + b)
}

///|
pub fn checked_sub(a : Int64, b : Int64) -> Result[Int64, BudgetError] {
  if a < 0L || b < 0L || b > a {
    Err(InvalidAmount)
  } else {
    Ok(a - b)
  }
}

///|
pub fn checked_mul(a : Int64, b : Int64) -> Result[Int64, BudgetError] {
  if a < 0L || b < 0L {
    return Err(InvalidAmount)
  }
  if a != 0L && b > 9223372036854775807L / a {
    return Err(Overflow)
  }
  Ok(a * b)
}

///|
/// CostV1 counts UTF-8 without allocating a second encoded string.
pub fn utf8_bytes(value : String) -> Int64 {
  let mut size = 0L
  for character in value {
    let code = character.to_int()
    size += if code < 0x80 {
      1L
    } else if code < 0x800 {
      2L
    } else if code < 0x10000 {
      3L
    } else {
      4L
    }
  }
  size
}

///|
pub fn message_cost(
  topic : String,
  payload_bytes : Int64,
) -> Result[Int64, BudgetError] {
  match checked_add(utf8_bytes(topic), payload_bytes) {
    Ok(value) => checked_add(value, 96L)
    Err(error) => Err(error)
  }
}

///|
pub fn subscription_cost(filter : String) -> Int64 {
  utf8_bytes(filter) + 64L
}

///|
pub fn identity_cost(client_id : String, owner : String) -> Int64 {
  utf8_bytes(client_id) + utf8_bytes(owner) + 256L
}

///|
pub fn qos2_metadata_cost() -> Int64 {
  64L
}
