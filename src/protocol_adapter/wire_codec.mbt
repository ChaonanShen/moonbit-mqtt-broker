///|
pub fn decode_wire(
  frame : Bytes,
  phase : DecodePhase,
  direction : PacketDirection,
  limits : DecodeLimits,
) -> Result[WirePacket, WireError] {
  if frame.length() > limits.max_packet_bytes {
    return Err(WireLimitExceeded(0))
  }
  let version = match phase {
    Established(version) => version
    FirstConnect => {
      let detected : Result[ProtocolVersion, WireError] = try {
        let reader = WireReader::new(frame)
        if reader.u8() != 0x10 {
          raise InvalidWireValue(0)
        }
        let length = reader.vbi()
        if length != reader.remaining() {
          raise InvalidWireValue(reader.position())
        }
        if reader.utf8() != "MQTT" {
          raise InvalidWireValue(reader.position())
        }
        match reader.u8() {
          4 => Ok(V311)
          5 => Ok(V5)
          _ => Err(InvalidWireValue(reader.position()))
        }
      } catch {
        error => Err(error)
      }
      match detected {
        Ok(version) => version
        Err(error) => return Err(error)
      }
    }
  }
  match version {
    V311 =>
      match decode_packet(frame) {
        Ok(packet) =>
          match validate_direction(packet, direction) {
            Ok(_) => Ok(V311(packet))
            Err(error) => Err(LegacyCodec(error))
          }
        Err(error) => Err(LegacyCodec(error))
      }
    V5 => decode_v5(frame, direction, limits).map(packet => V5(packet))
  }
}

///|
pub fn encode_wire(
  packet : WirePacket,
  direction : PacketDirection,
  max_bytes : Int,
) -> Result[Bytes, WireError] {
  match packet {
    V311(packet) =>
      match encode_packet(packet) {
        Ok(bytes) =>
          if bytes.length() > max_bytes {
            Err(WireLimitExceeded(bytes.length()))
          } else {
            Ok(bytes)
          }
        Err(error) => Err(LegacyCodec(error))
      }
    V5(packet) => encode_v5(packet, direction, max_bytes)
  }
}

///|
pub fn measure_wire(
  packet : WirePacket,
  direction : PacketDirection,
) -> Result[Int, WireError] {
  encode_wire(packet, direction, 268435460).map(bytes => bytes.length())
}
