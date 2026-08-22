///|
pub(all) enum ServerError {
  InvalidConfiguration(String)
  ConnectionIdExhausted
  RuntimeInvariantViolation(String)
} derive(Eq, Debug)
