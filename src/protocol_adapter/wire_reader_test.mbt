///|
fn tested_vbi(data : Bytes) -> Result[Int, WireError] {
  Ok(WireReader::new(data).vbi()) catch {
    error => Err(error)
  }
}

///|
fn tested_utf8(data : Bytes) -> Result[String, WireError] {
  Ok(WireReader::new(data).utf8()) catch {
    error => Err(error)
  }
}

///|
test "C-T01 wire integer bounds and canonical VBI" {
  let input = WireReader::new(b"\xff\xff\xff\xff\x7f")
  assert_eq(input.u32(), 0xffffffffU)
  assert_eq(input.vbi(), 127)
  input.finish()
  assert_true(tested_vbi(b"\x80\x00") is Err(MalformedVariableInteger(_)))
  assert_true(
    tested_vbi(b"\xff\xff\xff\xff") is Err(MalformedVariableInteger(_)),
  )
  assert_true(tested_vbi(b"\x80") is Err(Truncated(_)))
}

///|
test "C-T01 wire strings reject NUL and preserve BOM" {
  assert_true(tested_utf8(b"\x00\x01\x00") is Err(InvalidWireString(_)))
  assert_true(tested_utf8(b"\x00\x01\xff") is Err(InvalidWireString(_)))
  assert_eq(WireReader::new(b"\x00\x03\xef\xbb\xbf").utf8(), "\u{feff}")
  assert_eq(WireReader::new(b"\x00\x01\x00").binary16(), b"\x00")
}

///|
test "C-T01 wire writer stays within complete packet budget" {
  let writer = WireWriter::new(12)
  writer.vbi(268435455)
  writer.u32(0xffffffffU)
  writer.utf8("ab")
  assert_eq(writer.length(), 12)
  assert_eq(writer.finish(), b"\xff\xff\xff\x7f\xff\xff\xff\xff\x00\x02ab")
  let too_small : Result[Unit, WireError] = try {
    WireWriter::new(1).u16(2)
    Ok(())
  } catch {
    error => Err(error)
  }
  assert_true(too_small is Err(WireLimitExceeded(_)))
  let too_large : Result[Unit, WireError] = try {
    WireWriter::new(4).vbi(268435456)
    Ok(())
  } catch {
    error => Err(error)
  }
  assert_true(too_large is Err(InvalidWireValue(_)))
}
