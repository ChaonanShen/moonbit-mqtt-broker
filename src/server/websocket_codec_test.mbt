///|
fn masked_ws_frame(opcode : Int, fin : Bool, body : Bytes) -> Bytes {
  let first = (if fin { 0x80 } else { 0 }) | opcode
  let data : Array[Byte] = [first.to_byte(), (0x80 | body.length()).to_byte()]
  let mask : Array[Byte] = [1, 2, 3, 4]
  for byte in mask {
    data.push(byte)
  }
  for index in 0..<body.length() {
    data.push((body[index].to_int() ^ mask[index % 4].to_int()).to_byte())
  }
  Bytes::from_array(data)
}

///|
test "websocket masked binary streams bytewise with ping interleaving" {
  let decoder = WebSocketDecoder::new(1024, 2048)
  let first = masked_ws_frame(2, false, b"abc")
  let ping = masked_ws_frame(9, true, b"x")
  let last = masked_ws_frame(0, true, b"def")
  let data : Array[Byte] = []
  let mut pings = 0
  for frame in [first, ping, last] {
    for index in 0..<frame.length() {
      assert_true(decoder.feed(Bytes::from_array([frame[index]])))
      for ;; {
        match decoder.next() {
          WsNeedMore => break
          WsBinary(bytes) => data.append(bytes.to_array())
          WsPing(bytes) => {
            assert_eq(bytes, b"x")
            pings += 1
          }
          _ => fail("unexpected websocket event")
        }
      }
    }
  }
  assert_eq(Bytes::from_array(data), b"abcdef")
  assert_eq(pings, 1)
}

///|
test "websocket rejects unmasked RSV text and broken continuation" {
  let decoder = WebSocketDecoder::new(1024, 2048)
  assert_true(decoder.feed(b"\x82\x01x"))
  assert_true(decoder.next() is WsInvalid(1002))
  let decoder = WebSocketDecoder::new(1024, 2048)
  assert_true(decoder.feed(b"\xc2\x80\x01\x02\x03\x04"))
  assert_true(decoder.next() is WsInvalid(1002))
  let decoder = WebSocketDecoder::new(1024, 2048)
  assert_true(decoder.feed(masked_ws_frame(1, true, b"hello")))
  assert_true(decoder.next() is WsInvalid(1003))
  let decoder = WebSocketDecoder::new(1024, 2048)
  assert_true(decoder.feed(masked_ws_frame(0, true, b"x")))
  assert_true(decoder.next() is WsInvalid(1002))
}

///|
test "websocket output is unmasked and uses the shortest length" {
  assert_eq(websocket_encode_frame(2, b"mqtt"), Some(b"\x82\x04mqtt"))
  assert_eq(websocket_encode_frame(9, b"x"), Some(b"\x89\x01x"))
  assert_true(websocket_encode_frame(9, Bytes::make(126, 0)) is None)
}

///|
test "websocket streams a 32 KiB masked frame from bounded chunks" {
  let decoder = WebSocketDecoder::new(65536, 65536)
  let frame : Array[Byte] = [0x82, 0xfe, 0x80, 0x00, 1, 2, 3, 4]
  for index in 0..<32768 {
    frame.push((0x5a ^ (index % 4 + 1)).to_byte())
  }
  let mut delivered = 0
  let mut offset = 0
  while offset < frame.length() {
    let end = if frame.length() - offset < 4096 {
      frame.length()
    } else {
      offset + 4096
    }
    assert_true(decoder.feed(Bytes::from_array(frame[offset:end].to_owned())))
    for ;; {
      match decoder.next() {
        WsNeedMore => break
        WsBinary(bytes) => {
          for byte in bytes {
            assert_eq(byte, 0x5a)
          }
          delivered += bytes.length()
        }
        _ => fail("unexpected event")
      }
    }
    assert_true(decoder.buffered_len() < 4110)
    offset = end
  }
  assert_eq(delivered, 32768)
}

///|
test "websocket rejects nonminimal and high-bit 64-bit lengths" {
  let short = WebSocketDecoder::new(1048576, 4194304)
  assert_true(short.feed(b"\x82\xfe\x00\x7d\x01\x02\x03\x04"))
  assert_true(short.next() is WsInvalid(1002))
  let high = WebSocketDecoder::new(1048576, 4194304)
  assert_true(
    high.feed(b"\x82\xff\x80\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04"),
  )
  assert_true(high.next() is WsInvalid(1002))
}
