///|
fn make_frame(header : Byte, remaining_length : Int) -> Bytes {
  let bytes = [header]
  let mut value = remaining_length
  for ;; {
    let mut digit = value % 128
    value = value / 128
    if value > 0 {
      digit = digit | 0x80
    }
    bytes.push(digit.to_byte())
    if value == 0 {
      break
    }
  }
  for index in 0..<remaining_length {
    bytes.push((index % 251).to_byte())
  }
  Bytes::from_array(bytes)
}

///|
test "empty and partial fixed headers need more data" {
  let decoder = FrameDecoder::new(1024, 1024)
  assert_eq(decoder.next(), FrameOutcome::NeedMoreData)
  assert_eq(decoder.push(b""[:]), Ok(()))
  assert_eq(decoder.push(b"\xc0"[:]), Ok(()))
  assert_eq(decoder.next(), FrameOutcome::NeedMoreData)
  assert_eq(decoder.push(b"\x00"[:]), Ok(()))
  assert_eq(decoder.next(), FrameOutcome::CompletePacket(b"\xc0\x00"))
}

///|
test "remaining length accepts one through four encoded bytes" {
  for size in [0, 128, 16384, 2097152] {
    let frame = make_frame(0x30, size)
    let decoder = FrameDecoder::new(frame.length() + 1, frame.length() + 1)
    assert_eq(decoder.push(frame[:]), Ok(()))
    assert_eq(decoder.next(), FrameOutcome::CompletePacket(frame))
  }
}

///|
test "every byte may arrive in a separate tcp chunk" {
  let frame = make_frame(0x30, 300)
  let decoder = FrameDecoder::new(1024, 1024)
  for index in 0..<frame.length() {
    assert_eq(decoder.push(frame[index:index + 1]), Ok(()))
    if index + 1 < frame.length() {
      assert_eq(decoder.next(), FrameOutcome::NeedMoreData)
    }
  }
  assert_eq(decoder.next(), FrameOutcome::CompletePacket(frame))
  assert_eq(decoder.buffered_len(), 0)
}

///|
test "sticky packets drain one at a time and retain a partial suffix" {
  let ping = b"\xc0\x00"
  let disconnect = b"\xe0\x00"
  let bytes : Array[Byte] = []
  for _ in 0..<5 {
    for byte in ping {
      bytes.push(byte)
    }
    for byte in disconnect {
      bytes.push(byte)
    }
  }
  bytes.push(0x30)
  let decoder = FrameDecoder::new(128, 128)
  assert_eq(decoder.push(Bytes::from_array(bytes)[:]), Ok(()))
  for index in 0..<10 {
    let expected = if index % 2 == 0 { ping } else { disconnect }
    assert_eq(decoder.next(), FrameOutcome::CompletePacket(expected))
  }
  assert_eq(decoder.buffered_len(), 1)
  assert_eq(decoder.next(), FrameOutcome::NeedMoreData)
}

///|
test "invalid remaining length fails permanently until reset" {
  let decoder = FrameDecoder::new(1024, 1024)
  let malformed = b"\x30\x80\x80\x80\x80\x00"
  assert_eq(decoder.push(malformed[:]), Ok(()))
  assert_eq(
    decoder.next(),
    FrameOutcome::MalformedPacket(FrameError::InvalidRemainingLength),
  )
  assert_eq(
    decoder.next(),
    FrameOutcome::MalformedPacket(FrameError::InvalidRemainingLength),
  )
  assert_eq(
    decoder.push(b"\xc0\x00"[:]),
    Err(FrameError::InvalidRemainingLength),
  )
  decoder.reset()
  assert_eq(decoder.push(b"\xc0\x00"[:]), Ok(()))
  assert_eq(decoder.next(), FrameOutcome::CompletePacket(b"\xc0\x00"))
}

///|
test "declared packet limit is enforced before payload arrives" {
  let decoder = FrameDecoder::new(100, 256)
  assert_eq(decoder.push(b"\x30\x7f"[:]), Ok(()))
  assert_eq(
    decoder.next(),
    FrameOutcome::MalformedPacket(FrameError::PacketTooLarge(129)),
  )
}

///|
test "packet size equality is accepted" {
  let frame = make_frame(0x30, 98)
  assert_eq(frame.length(), 100)
  let decoder = FrameDecoder::new(100, 100)
  assert_eq(decoder.push(frame[:]), Ok(()))
  assert_eq(decoder.next(), FrameOutcome::CompletePacket(frame))
}

///|
test "receive buffer equality is accepted and overflow rejected" {
  let exact = FrameDecoder::new(128, 4)
  assert_eq(exact.push(b"\x30\x05ab"[:]), Ok(()))
  assert_eq(exact.buffered_len(), 4)
  let overflow = FrameDecoder::new(128, 4)
  assert_eq(
    overflow.push(b"\x30\x05abc"[:]),
    Err(FrameError::BufferTooLarge(5)),
  )
  assert_eq(
    overflow.next(),
    FrameOutcome::MalformedPacket(FrameError::BufferTooLarge(5)),
  )
}

///|
test "zero length control frames are independent packets" {
  let decoder = FrameDecoder::new(16, 16)
  assert_eq(decoder.push(b"\xc0\x00\xd0\x00\xe0\x00"[:]), Ok(()))
  assert_eq(decoder.next(), FrameOutcome::CompletePacket(b"\xc0\x00"))
  assert_eq(decoder.next(), FrameOutcome::CompletePacket(b"\xd0\x00"))
  assert_eq(decoder.next(), FrameOutcome::CompletePacket(b"\xe0\x00"))
  assert_eq(decoder.next(), FrameOutcome::NeedMoreData)
}

///|
test "one thousand deterministic chunk matrices preserve bytes exactly" {
  let frame = make_frame(0x30, 61)
  for iteration in 0..<1000 {
    let decoder = FrameDecoder::new(128, 128)
    let mut offset = 0
    while offset < frame.length() {
      let width = (iteration * 17 + offset * 7) % 11 + 1
      let end = if offset + width < frame.length() {
        offset + width
      } else {
        frame.length()
      }
      assert_eq(decoder.push(frame[offset:end]), Ok(()))
      offset = end
    }
    assert_eq(decoder.next(), FrameOutcome::CompletePacket(frame))
    assert_eq(decoder.next(), FrameOutcome::NeedMoreData)
  }
}

///|
test "invalid limits produce a stable malformed state" {
  let decoder = FrameDecoder::new(1, 1)
  assert_eq(
    decoder.next(),
    FrameOutcome::MalformedPacket(
      FrameError::InvalidConfiguration("max_packet_size must be at least 2"),
    ),
  )
}
