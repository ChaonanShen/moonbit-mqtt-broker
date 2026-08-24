///|
pub(all) suberror PersistenceError {
  InvalidConfiguration(String)
  SnapshotTooLarge(actual~ : Int64, limit~ : Int64)
  Truncated(offset~ : Int, needed~ : Int, remaining~ : Int)
  InvalidMagic
  UnsupportedEnvelopeVersion(Int)
  UnknownFlags(Int)
  LengthMismatch(declared~ : Int64, actual~ : Int64)
  ChecksumMismatch(expected~ : UInt, actual~ : UInt)
  TrailingData(offset~ : Int)
  InvalidUtf8(offset~ : Int)
  InvalidValue(field~ : String, offset~ : Int)
  LimitExceeded(resource~ : String, actual~ : Int64, limit~ : Int64)
  SnapshotImport(String)
  FileSystem(operation~ : String, path~ : String)
  LockConflict(String)
  DurabilityUncertain(String)
} derive(Eq, Debug)

///|
pub fn PersistenceError::category(self : PersistenceError) -> String {
  match self {
    InvalidConfiguration(_) => "invalid-configuration"
    SnapshotTooLarge(..) => "snapshot-too-large"
    Truncated(..) => "truncated"
    InvalidMagic => "invalid-magic"
    UnsupportedEnvelopeVersion(_) => "unsupported-envelope-version"
    UnknownFlags(_) => "unknown-flags"
    LengthMismatch(..) => "length-mismatch"
    ChecksumMismatch(..) => "checksum-mismatch"
    TrailingData(..) => "trailing-data"
    InvalidUtf8(..) => "invalid-utf8"
    InvalidValue(..) => "invalid-value"
    LimitExceeded(..) => "limit-exceeded"
    SnapshotImport(_) => "snapshot-import"
    FileSystem(..) => "filesystem"
    LockConflict(_) => "lock-conflict"
    DurabilityUncertain(_) => "durability-uncertain"
  }
}
