///|
pub struct WireWriter {
  bytes : Array[Byte]
  max_bytes : Int
}

///|
pub fn WireWriter::new(max_bytes : Int) -> WireWriter {
  { bytes: [], max_bytes }
}

///|
pub fn WireWriter::length(self : WireWriter) -> Int {
  self.bytes.length()
}

///|
fn WireWriter::reserve(self : WireWriter, count : Int) -> Unit raise WireError {
  if count < 0 ||
    self.max_bytes < self.bytes.length() ||
    count > self.max_bytes - self.bytes.length() {
    raise WireLimitExceeded(self.bytes.length())
  }
}

///|
pub fn WireWriter::u8(self : WireWriter, value : Int) -> Unit raise WireError {
  if value < 0 || value > 255 {
    raise InvalidWireValue(self.bytes.length())
  }
  self.reserve(1)
  self.bytes.push(value.to_byte())
}

///|
pub fn WireWriter::u16(self : WireWriter, value : Int) -> Unit raise WireError {
  if value < 0 || value > 65535 {
    raise InvalidWireValue(self.bytes.length())
  }
  self.reserve(2)
  self.bytes.push((value >> 8).to_byte())
  self.bytes.push(value.to_byte())
}

///|
pub fn WireWriter::u32(self : WireWriter, value : UInt) -> Unit raise WireError {
  self.reserve(4)
  self.bytes.push((value >> 24).to_byte())
  self.bytes.push((value >> 16).to_byte())
  self.bytes.push((value >> 8).to_byte())
  self.bytes.push(value.to_byte())
}

///|
pub fn WireWriter::vbi(self : WireWriter, value : Int) -> Unit raise WireError {
  if value < 0 || value > 268435455 {
    raise InvalidWireValue(self.bytes.length())
  }
  let mut remaining = value
  for _ in 0..<4 {
    let mut digit = remaining % 128
    remaining /= 128
    if remaining != 0 {
      digit = digit | 0x80
    }
    self.u8(digit)
    if remaining == 0 {
      return
    }
  }
}

///|
pub fn WireWriter::raw(
  self : WireWriter,
  value : Bytes,
) -> Unit raise WireError {
  self.reserve(value.length())
  for byte in value {
    self.bytes.push(byte)
  }
}

///|
pub fn WireWriter::binary16(
  self : WireWriter,
  value : Bytes,
) -> Unit raise WireError {
  if value.length() > 65535 {
    raise WireLimitExceeded(self.bytes.length())
  }
  self.reserve(value.length() + 2)
  self.u16(value.length())
  self.raw(value)
}

///|
pub fn WireWriter::utf8(
  self : WireWriter,
  value : String,
) -> Unit raise WireError {
  let encoded = @utf8.encode(value)
  for byte in encoded {
    if byte.to_int() == 0 {
      raise InvalidWireString(self.bytes.length())
    }
  }
  self.binary16(encoded)
}

///|
pub fn WireWriter::finish(self : WireWriter) -> Bytes {
  Bytes::from_array(self.bytes)
}
