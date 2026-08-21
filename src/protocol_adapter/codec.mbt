///|
/// Decode exactly one complete MQTT packet. TCP stream state belongs to the
/// framing package and is intentionally absent from this interface.
pub fn decode_packet(frame : Bytes) -> Result[Packet, CodecError] {
  candidate_decode_packet(frame)
}

///|
pub fn encode_packet(packet : Packet) -> Result[Bytes, CodecError] {
  candidate_encode_packet(packet)
}

///|
pub fn codec_backend() -> String {
  "zbhzs1/moonbit-mqtt@0.1.0"
}
