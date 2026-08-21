///|
suberror GateError {
  GateError(String)
} derive(Debug)

///|
fn json_string_field(object : Map[String, Json], key : String) -> String raise {
  match object.get(key) {
    Some(String(value)) => value
    _ => raise GateError("missing string field: " + key)
  }
}

///|
fn hex_nibble(char : Char) -> Int raise {
  match char {
    '0'..='9' => char.to_int() - '0'.to_int()
    'a'..='f' => char.to_int() - 'a'.to_int() + 10
    'A'..='F' => char.to_int() - 'A'.to_int() + 10
    _ => raise GateError("invalid hex digit")
  }
}

///|
fn decode_hex(value : String) -> Bytes raise {
  if value.length() % 2 != 0 {
    raise GateError("odd-length hex fixture")
  }
  let chars = value.to_array()
  let bytes : Array[Byte] = []
  for index in 0..<(chars.length() / 2) {
    bytes.push(
      ((hex_nibble(chars[index * 2]) << 4) | hex_nibble(chars[index * 2 + 1])).to_byte(),
    )
  }
  Bytes::from_array(bytes)
}

///|
fn packet_type(packet : @protocol.Packet) -> String {
  match packet {
    Connect(_) => "connect"
    Connack(_) => "connack"
    Publish(_) => "publish"
    Puback(_) => "puback"
    Subscribe(_) => "subscribe"
    Suback(_) => "suback"
    Unsubscribe(_) => "unsubscribe"
    Unsuback(_) => "unsuback"
    Pingreq => "pingreq"
    Pingresp => "pingresp"
    Disconnect => "disconnect"
  }
}

///|
fn error_category(error : @protocol.CodecError) -> String {
  match error {
    InvalidFixedHeader(_) => "invalid_fixed_header"
    InvalidRemainingLength(_) => "invalid_remaining_length"
    InvalidFlags(_) => "invalid_flags"
    InvalidProtocolName(_) => "invalid_protocol_name"
    InvalidProtocolLevel(_) => "invalid_protocol_level"
    InvalidUtf8(_) => "invalid_utf8"
    InvalidPacketId(_) => "invalid_packet_id"
    InvalidPacketShape(_) => "invalid_packet_shape"
    InvalidDirection(_) => "invalid_direction"
    TrailingBytes(_) => "trailing_bytes"
    UnsupportedPacketType(_) => "unsupported_packet_type"
    UnsupportedQoS(_) => "unsupported_qos"
    PacketTooLarge(_) => "packet_too_large"
    BackendFailure(_) => "backend_failure"
  }
}

///|
fn parse_fixture(line : String) -> Map[String, Json] raise {
  let parsed = @json.parse(line) catch {
    _ => raise GateError("fixture is not valid JSON")
  }
  guard parsed is Object(object) else {
    raise GateError("fixture must be a JSON object")
  }
  object
}

///|
fn check_valid(line : String) -> Unit raise {
  let fixture = parse_fixture(line)
  let id = json_string_field(fixture, "id")
  let expected_type = json_string_field(fixture, "packet_type")
  let direction = match json_string_field(fixture, "direction") {
    "client_to_server" => @protocol.PacketDirection::ClientToServer
    "server_to_client" => @protocol.PacketDirection::ServerToClient
    _ => raise GateError(id + ": invalid direction fixture")
  }
  let bytes = decode_hex(json_string_field(fixture, "hex"))
  let packet = match @protocol.decode_packet(bytes) {
    Ok(value) => value
    Err(error) =>
      raise GateError(id + ": decode failed: " + error_category(error))
  }
  if packet_type(packet) != expected_type {
    raise GateError(id + ": decoded packet type differs")
  }
  match @protocol.validate_direction(packet, direction) {
    Ok(_) => ()
    Err(_) => raise GateError(id + ": direction validation failed")
  }
  match @protocol.encode_packet(packet) {
    Ok(encoded) =>
      if encoded != bytes {
        raise GateError(id + ": candidate round trip changed canonical bytes")
      }
    Err(error) =>
      raise GateError(id + ": encode failed: " + error_category(error))
  }
}

///|
fn check_malformed(line : String) -> Unit raise {
  let fixture = parse_fixture(line)
  let id = json_string_field(fixture, "id")
  let expected = json_string_field(fixture, "expected_category")
  let bytes = decode_hex(json_string_field(fixture, "hex"))
  match @protocol.decode_packet(bytes) {
    Ok(_) => raise GateError(id + ": malformed packet was accepted")
    Err(error) =>
      if error_category(error) != expected {
        raise GateError(
          id + ": expected " + expected + ", got " + error_category(error),
        )
      }
  }
}

///|
async fn main {
  let valid = @fs.read_file("tests/fixtures/codec/valid-vectors.jsonl").text()
  let malformed = @fs.read_file("tests/fixtures/codec/malformed-vectors.jsonl").text()
  let mut valid_count = 0
  for line in valid.split("\n") {
    if !line.is_empty() {
      check_valid(line.to_owned()) catch {
        GateError(message) => {
          println(message)
          raise GateError(message)
        }
        error => raise error
      }
      valid_count = valid_count + 1
    }
  }
  let mut malformed_count = 0
  for line in malformed.split("\n") {
    if !line.is_empty() {
      check_malformed(line.to_owned()) catch {
        GateError(message) => {
          println(message)
          raise GateError(message)
        }
        error => raise error
      }
      malformed_count = malformed_count + 1
    }
  }
  if valid_count != 1000 {
    raise GateError("expected exactly 1000 valid fixtures")
  }
  println(
    "{\"backend\":\"" +
    @protocol.codec_backend() +
    "\",\"valid\":" +
    valid_count.to_string() +
    ",\"malformed\":" +
    malformed_count.to_string() +
    ",\"semantic_differences\":0,\"panic_or_hang\":0}",
  )
}
