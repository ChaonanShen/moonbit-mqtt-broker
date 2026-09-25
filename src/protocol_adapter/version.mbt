///|
pub(all) enum ProtocolVersion {
  V311
  V5
} derive(Eq, Debug)

///|
pub(all) enum DecodePhase {
  FirstConnect
  Established(ProtocolVersion)
} derive(Eq, Debug)
