///|
priv struct BinaryWriter {
  max_bytes : Int
  bytes : Array[Byte]
}

///|
fn BinaryWriter::new(max_bytes? : Int = 2147483647) -> BinaryWriter {
  { max_bytes, bytes: [] }
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
  self.require_capacity(1)
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
  self.require_capacity(2)
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
fn BinaryWriter::write_u32_bits(
  self : BinaryWriter,
  value : UInt,
) -> Unit raise PersistenceError {
  self.require_capacity(4)
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
fn BinaryWriter::write_raw(
  self : BinaryWriter,
  value : BytesView,
) -> Unit raise PersistenceError {
  self.require_capacity(value.length())
  for byte in value {
    self.bytes.push(byte)
  }
}

///|
fn BinaryWriter::write_string(
  self : BinaryWriter,
  value : String,
) -> Unit raise PersistenceError {
  let length = @budget.utf8_bytes(value)
  if length > 65535L {
    raise LimitExceeded(resource="string-bytes", actual=length, limit=65535L)
  }
  self.require_capacity(length.to_int() + 4)
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

///|
fn BinaryWriter::require_capacity(
  self : BinaryWriter,
  count : Int,
) -> Unit raise PersistenceError {
  if count < 0 || count > self.max_bytes - self.bytes.length() {
    raise SnapshotTooLarge(
      actual=self.bytes.length().to_int64() + count.to_int64(),
      limit=self.max_bytes.to_int64(),
    )
  }
}
