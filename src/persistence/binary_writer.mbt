///|
priv struct BinaryWriter {
  bytes : Array[Byte]
}

///|
fn BinaryWriter::new() -> BinaryWriter {
  { bytes: [] }
}

///|
fn BinaryWriter::write_u8(
  self : BinaryWriter,
  value : Int,
  field : String,
) -> Unit raise PersistenceError {
  if value < 0 || value > 255 {
    raise InvalidValue(field~, offset=self.bytes.length())
  }
  self.bytes.push(value.to_byte())
}

///|
fn BinaryWriter::write_u16(
  self : BinaryWriter,
  value : Int,
  field : String,
) -> Unit raise PersistenceError {
  if value < 0 || value > 65535 {
    raise InvalidValue(field~, offset=self.bytes.length())
  }
  self.bytes.push(((value >> 8) & 0xff).to_byte())
  self.bytes.push((value & 0xff).to_byte())
}

///|
fn BinaryWriter::write_u32(
  self : BinaryWriter,
  value : Int,
  field : String,
) -> Unit raise PersistenceError {
  if value < 0 {
    raise InvalidValue(field~, offset=self.bytes.length())
  }
  self.write_u32_bits(value.reinterpret_as_uint())
}

///|
fn BinaryWriter::write_u32_bits(self : BinaryWriter, value : UInt) -> Unit {
  self.bytes.push((value >> 24).to_byte())
  self.bytes.push((value >> 16).to_byte())
  self.bytes.push((value >> 8).to_byte())
  self.bytes.push(value.to_byte())
}

///|
fn BinaryWriter::write_u64_length(
  self : BinaryWriter,
  value : Int,
) -> Unit raise PersistenceError {
  if value < 0 {
    raise InvalidValue(field="payload-length", offset=self.bytes.length())
  }
  self.write_u32_bits(0U)
  self.write_u32(value, "payload-length")
}

///|
fn BinaryWriter::write_raw(self : BinaryWriter, value : BytesView) -> Unit {
  for byte in value {
    self.bytes.push(byte)
  }
}

///|
fn BinaryWriter::write_string(
  self : BinaryWriter,
  value : String,
) -> Unit raise PersistenceError {
  let encoded = @utf8.encode(value)
  if encoded.length() > 65535 {
    raise LimitExceeded(
      resource="string-bytes",
      actual=encoded.length().to_int64(),
      limit=65535L,
    )
  }
  self.write_u32(encoded.length(), "string-length")
  self.write_raw(encoded)
}

///|
fn BinaryWriter::write_bytes(
  self : BinaryWriter,
  value : Bytes,
) -> Unit raise PersistenceError {
  self.write_u32(value.length(), "bytes-length")
  self.write_raw(value)
}

///|
fn BinaryWriter::finish(self : BinaryWriter) -> Bytes {
  Bytes::from_array(self.bytes)
}
