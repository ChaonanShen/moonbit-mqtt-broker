///|
/// Decode one MQTT 3.1.1 packet. The public Packet API remains version fixed.
pub fn decode_packet(frame : Bytes) -> Result[Packet, CodecError] {
  decode_v311(frame)
}

///|
pub fn encode_packet(packet : Packet) -> Result[Bytes, CodecError] {
  encode_v311(packet)
}

///|
pub fn codec_backend() -> String {
  "moonbit-mqtt-broker/native"
}
