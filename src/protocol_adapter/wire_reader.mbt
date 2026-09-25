///|
pub(all) suberror WireError {
  Truncated(Int)
  MalformedVariableInteger(Int)
  InvalidWireString(Int)
  InvalidWireValue(Int)
  WireLimitExceeded(Int)
  LegacyCodec(CodecError)
  WireInvalidFlags(Int)
  WireInvalidPacketId(Int)
  WireInvalidProtocolName(Int)
  WireInvalidProtocolLevel(Int)
  WireUnsupportedQoS(Int)
} derive(Eq, Debug)

///|
pub struct WireReader {
  data : Bytes
  mut offset : Int
  end : Int
}

///|
pub fn WireReader::new(data : Bytes) -> WireReader {
  { data, offset: 0, end: data.length() }
}

///|
pub fn WireReader::bounded(
  data : Bytes,
  start : Int,
  end : Int,
) -> WireReader raise WireError {
  if start < 0 || end < start || end > data.length() {
    raise Truncated(start)
  }
  { data, offset: start, end }
}

///|
pub fn WireReader::position(self : WireReader) -> Int {
  self.offset
}

///|
pub fn WireReader::remaining(self : WireReader) -> Int {
  self.end - self.offset
}

///|
fn WireReader::require(self : WireReader, count : Int) -> Unit raise WireError {
  if count < 0 || count > self.remaining() {
    raise Truncated(self.offset)
  }
}

///|
pub fn WireReader::u8(self : WireReader) -> Int raise WireError {
  self.require(1)
  let value = self.data[self.offset].to_int()
  self.offset += 1
  value
}

///|
pub fn WireReader::u16(self : WireReader) -> Int raise WireError {
  self.require(2)
  let value = (self.data[self.offset].to_int() << 8) |
    self.data[self.offset + 1].to_int()
  self.offset += 2
  value
}

///|
pub fn WireReader::u32(self : WireReader) -> UInt raise WireError {
  self.require(4)
  let value = (self.data[self.offset].to_uint() << 24) |
    (self.data[self.offset + 1].to_uint() << 16) |
    (self.data[self.offset + 2].to_uint() << 8) |
    self.data[self.offset + 3].to_uint()
  self.offset += 4
  value
}

///|
/// MQTT Variable Byte Integer, including the shortest-encoding rule.
pub fn WireReader::vbi(self : WireReader) -> Int raise WireError {
  let start = self.offset
  let mut value = 0
  let mut multiplier = 1
  for digit in 0..<4 {
    let encoded = self.u8()
    value += (encoded & 0x7f) * multiplier
    if (encoded & 0x80) == 0 {
      if digit > 0 && value < multiplier {
        raise MalformedVariableInteger(start)
      }
      return value
    }
    multiplier *= 128
  }
  raise MalformedVariableInteger(start)
}

///|
fn WireReader::skip(self : WireReader, count : Int) -> Unit raise WireError {
  self.require(count)
  self.offset += count
}

///|
pub fn WireReader::raw(self : WireReader, count : Int) -> Bytes raise WireError {
  self.require(count)
  let start = self.offset
  self.offset += count
  self.data[start:self.offset].to_owned()
}

///|
pub fn WireReader::binary16(self : WireReader) -> Bytes raise WireError {
  let count = self.u16()
  self.raw(count)
}

///|
pub fn WireReader::utf8(self : WireReader) -> String raise WireError {
  let start = self.offset
  let bytes = self.binary16()
  for byte in bytes {
    if byte.to_int() == 0 {
      raise InvalidWireString(start)
    }
  }
  @utf8.decode(bytes) catch {
    _ => raise InvalidWireString(start)
  }
}

///|
pub fn WireReader::finish(self : WireReader) -> Unit raise WireError {
  if self.remaining() != 0 {
    raise InvalidWireValue(self.offset)
  }
}
