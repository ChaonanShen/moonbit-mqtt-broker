///|
priv struct BinaryReader {
  data : Bytes
  mut offset : Int
}

///|
fn BinaryReader::new(data : Bytes) -> BinaryReader {
  { data, offset: 0 }
}

///|
fn BinaryReader::position(self : BinaryReader) -> Int {
  self.offset
}

///|
fn BinaryReader::remaining(self : BinaryReader) -> Int {
  self.data.length() - self.offset
}

///|
fn BinaryReader::require(
  self : BinaryReader,
  count : Int,
) -> Unit raise PersistenceError {
  if count < 0 || count > self.remaining() {
    raise Truncated(
      offset=self.offset,
      needed=if count < 0 { 0 } else { count },
      remaining=self.remaining(),
    )
  }
}

///|
fn BinaryReader::read_u8(self : BinaryReader) -> Int raise PersistenceError {
  self.require(1)
  let value = self.data[self.offset].to_int()
  self.offset = self.offset + 1
  value
}

///|
fn BinaryReader::read_u16(self : BinaryReader) -> Int raise PersistenceError {
  self.require(2)
  let value = (self.data[self.offset].to_int() << 8) |
    self.data[self.offset + 1].to_int()
  self.offset = self.offset + 2
  value
}

///|
fn BinaryReader::read_u32_bits(
  self : BinaryReader,
) -> UInt raise PersistenceError {
  self.require(4)
  let value = (self.data[self.offset].to_uint() << 24) |
    (self.data[self.offset + 1].to_uint() << 16) |
    (self.data[self.offset + 2].to_uint() << 8) |
    self.data[self.offset + 3].to_uint()
  self.offset = self.offset + 4
  value
}

///|
fn BinaryReader::read_u32(
  self : BinaryReader,
  resource : String,
) -> Int raise PersistenceError {
  let value = self.read_u32_bits()
  if value > 0x7fffffffU {
    raise LimitExceeded(resource~, actual=value.to_int64(), limit=2147483647L)
  }
  value.reinterpret_as_int()
}

///|
fn BinaryReader::read_u64_length(
  self : BinaryReader,
) -> Int raise PersistenceError {
  let start = self.offset
  let high = self.read_u32_bits()
  let low = self.read_u32_bits()
  if high != 0U || low > 0x7fffffffU {
    raise LimitExceeded(
      resource="payload-length",
      actual=2147483648L,
      limit=2147483647L,
    )
  }
  ignore(start)
  low.reinterpret_as_int()
}

///|
fn BinaryReader::read_raw(
  self : BinaryReader,
  count : Int,
) -> Bytes raise PersistenceError {
  self.require(count)
  let start = self.offset
  self.offset = self.offset + count
  self.data[start:self.offset].to_owned()
}

///|
fn BinaryReader::read_string(
  self : BinaryReader,
) -> String raise PersistenceError {
  let length_offset = self.offset
  let length = self.read_u32("string-length")
  if length > 65535 {
    raise LimitExceeded(
      resource="string-bytes",
      actual=length.to_int64(),
      limit=65535L,
    )
  }
  let bytes = self.read_raw(length)
  @utf8.decode(bytes) catch {
    _ => raise InvalidUtf8(offset=length_offset)
  }
}

///|
fn BinaryReader::read_bytes(
  self : BinaryReader,
  max_length : Int,
) -> Bytes raise PersistenceError {
  let length = self.read_u32("message-payload-bytes")
  if length > max_length {
    raise LimitExceeded(
      resource="message-payload-bytes",
      actual=length.to_int64(),
      limit=max_length.to_int64(),
    )
  }
  self.read_raw(length)
}
