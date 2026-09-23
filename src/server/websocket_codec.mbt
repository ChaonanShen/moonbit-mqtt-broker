///|
pub(all) enum WebSocketEvent {
  WsNeedMore
  WsBinary(Bytes)
  WsPing(Bytes)
  WsPong
  WsClose(Bytes)
  WsInvalid(Int)
} derive(Eq, Debug)

///|
pub struct WebSocketDecoder {
  mut raw : Array[Byte]
  max_frame_bytes : Int
  max_message_bytes : Int
  mut fragmented : Bool
  mut message_bytes : Int64
  mut closed : Bool
  mut frame_active : Bool
  mut frame_remaining : Int
  mut frame_opcode : Int
  mut frame_mask : Bytes
  mut frame_mask_offset : Int
  mut control_payload : Array[Byte]
}

///|
pub fn WebSocketDecoder::new(
  max_frame_bytes : Int,
  max_message_bytes : Int,
) -> WebSocketDecoder {
  {
    raw: [],
    max_frame_bytes,
    max_message_bytes,
    fragmented: false,
    message_bytes: 0L,
    closed: false,
    frame_active: false,
    frame_remaining: 0,
    frame_opcode: 0,
    frame_mask: b"\x00\x00\x00\x00",
    frame_mask_offset: 0,
    control_payload: [],
  }
}

///|
pub fn WebSocketDecoder::buffered_len(self : WebSocketDecoder) -> Int {
  self.raw.length() + self.control_payload.length()
}

///|
pub fn WebSocketDecoder::feed(self : WebSocketDecoder, bytes : Bytes) -> Bool {
  if self.closed || bytes.length() > 4110 - self.raw.length() {
    return false
  }
  for byte in bytes {
    self.raw.push(byte)
  }
  true
}

///|
fn websocket_valid_close_code(code : Int) -> Bool {
  code >= 1000 &&
  code < 5000 &&
  code != 1004 &&
  code != 1005 &&
  code != 1006 &&
  code != 1015 &&
  (code < 1016 || code >= 3000)
}

///|
fn WebSocketDecoder::drop_raw(self : WebSocketDecoder, count : Int) -> Unit {
  let remaining : Array[Byte] = []
  for index in count..<self.raw.length() {
    remaining.push(self.raw[index])
  }
  self.raw = remaining
}

///|
fn WebSocketDecoder::control_result(self : WebSocketDecoder) -> WebSocketEvent {
  let opcode = self.frame_opcode
  let payload = Bytes::from_array(self.control_payload)
  self.control_payload = []
  self.frame_active = false
  match opcode {
    8 => {
      if payload.length() == 1 {
        return WsInvalid(1002)
      }
      if payload.length() >= 2 {
        let code = payload[0].to_int() * 256 + payload[1].to_int()
        if !websocket_valid_close_code(code) {
          return WsInvalid(1002)
        }
        let reason = Bytes::from_array(payload.to_array()[2:].to_owned())
        ignore(@utf8.decode(reason)) catch {
          _ => return WsInvalid(1007)
        }
      }
      self.closed = true
      WsClose(payload)
    }
    9 => WsPing(payload)
    10 => WsPong
    _ => WsInvalid(1002)
  }
}

///|
pub fn WebSocketDecoder::next(self : WebSocketDecoder) -> WebSocketEvent {
  if self.closed {
    return WsInvalid(1002)
  }
  if !self.frame_active {
    if self.raw.length() < 2 {
      return WsNeedMore
    }
    let first = self.raw[0].to_int()
    let second = self.raw[1].to_int()
    let fin = (first & 0x80) != 0
    let opcode = first & 0x0f
    if (first & 0x70) != 0 || (second & 0x80) == 0 {
      return WsInvalid(1002)
    }
    let control = opcode >= 8
    if !(opcode == 0 ||
      opcode == 1 ||
      opcode == 2 ||
      opcode == 8 ||
      opcode == 9 ||
      opcode == 10) ||
      (control && !fin) {
      return WsInvalid(1002)
    }
    let short_length = second & 0x7f
    let mut header = 2
    let mut length = short_length.to_int64()
    if short_length == 126 {
      if self.raw.length() < 4 {
        return WsNeedMore
      }
      length = self.raw[2].to_int().to_int64() * 256L +
        self.raw[3].to_int().to_int64()
      if length < 126L {
        return WsInvalid(1002)
      }
      header = 4
    } else if short_length == 127 {
      if self.raw.length() < 10 {
        return WsNeedMore
      }
      if (self.raw[2].to_int() & 0x80) != 0 {
        return WsInvalid(1002)
      }
      length = 0L
      for index in 2..<10 {
        if length > self.max_frame_bytes.to_int64() {
          return WsInvalid(1009)
        }
        length = length * 256L + self.raw[index].to_int().to_int64()
      }
      if length < 65536L {
        return WsInvalid(1002)
      }
      header = 10
    }
    if control && length > 125L {
      return WsInvalid(1002)
    }
    if length > self.max_frame_bytes.to_int64() {
      return WsInvalid(1009)
    }
    if self.raw.length() < header + 4 {
      return WsNeedMore
    }
    if opcode == 1 {
      return WsInvalid(1003)
    }
    if (opcode == 0 && !self.fragmented) || (opcode == 2 && self.fragmented) {
      return WsInvalid(1002)
    }
    if opcode == 2 {
      self.message_bytes = 0L
    }
    if !control {
      self.message_bytes += length
      if self.message_bytes > self.max_message_bytes.to_int64() {
        return WsInvalid(1009)
      }
      self.fragmented = !fin
    }
    self.frame_mask = Bytes::from_array([
      self.raw[header],
      self.raw[header + 1],
      self.raw[header + 2],
      self.raw[header + 3],
    ])
    self.frame_mask_offset = 0
    self.frame_remaining = length.to_int()
    self.frame_opcode = opcode
    self.control_payload = []
    self.frame_active = true
    self.drop_raw(header + 4)
  }
  if self.frame_remaining == 0 {
    if self.frame_opcode >= 8 {
      return self.control_result()
    }
    self.frame_active = false
    return WsBinary(b"")
  }
  if self.raw.is_empty() {
    return WsNeedMore
  }
  let count = if self.raw.length() < self.frame_remaining {
    self.raw.length()
  } else {
    self.frame_remaining
  }
  let payload : Array[Byte] = []
  for index in 0..<count {
    payload.push(
      (self.raw[index].to_int() ^
      self.frame_mask[(self.frame_mask_offset + index) % 4].to_int()).to_byte(),
    )
  }
  self.drop_raw(count)
  self.frame_remaining -= count
  self.frame_mask_offset += count
  if self.frame_opcode >= 8 {
    self.control_payload.append(payload)
    if self.frame_remaining == 0 {
      self.control_result()
    } else {
      WsNeedMore
    }
  } else {
    if self.frame_remaining == 0 {
      self.frame_active = false
    }
    WsBinary(Bytes::from_array(payload))
  }
}

///|
pub fn websocket_encode_frame(opcode : Int, payload : Bytes) -> Bytes? {
  if payload.length() > 65535 ||
    !(opcode == 0 || opcode == 2 || opcode == 8 || opcode == 9 || opcode == 10) ||
    (opcode >= 8 && payload.length() > 125) {
    return None
  }
  let bytes : Array[Byte] = [(0x80 | opcode).to_byte()]
  if payload.length() < 126 {
    bytes.push(payload.length().to_byte())
  } else {
    bytes.push(126)
    bytes.push((payload.length() >> 8).to_byte())
    bytes.push((payload.length() & 0xff).to_byte())
  }
  for byte in payload {
    bytes.push(byte)
  }
  Some(Bytes::from_array(bytes))
}
