///|
pub(all) enum FrameError {
  InvalidConfiguration(String)
  InvalidRemainingLength
  PacketTooLarge(Int)
  BufferTooLarge(Int)
} derive(Eq, Debug)

///|
pub(all) enum FrameOutcome {
  NeedMoreData
  CompletePacket(Bytes)
  MalformedPacket(FrameError)
} derive(Eq, Debug)

///|
/// Stateful, bounded MQTT stream decoder. It only determines packet boundaries;
/// fixed-header flags and packet contents are validated by the codec layer.
pub struct FrameDecoder {
  max_packet_size : Int
  max_buffer_size : Int
  priv mut buffer : Array[Byte]
  priv mut failed : FrameError?
}

///|
pub fn FrameDecoder::new(
  max_packet_size : Int,
  max_buffer_size : Int,
) -> FrameDecoder {
  let failed = if max_packet_size < 2 {
    Some(InvalidConfiguration("max_packet_size must be at least 2"))
  } else if max_buffer_size < 2 {
    Some(InvalidConfiguration("max_buffer_size must be at least 2"))
  } else {
    None
  }
  { max_packet_size, max_buffer_size, buffer: [], failed }
}

///|
pub fn FrameDecoder::push(
  self : FrameDecoder,
  chunk : BytesView,
) -> Result[Unit, FrameError] {
  if self.failed is Some(error) {
    return Err(error)
  }
  let next_len = self.buffer.length() + chunk.length()
  if next_len > self.max_buffer_size {
    let error = BufferTooLarge(next_len)
    self.failed = Some(error)
    return Err(error)
  }
  for byte in chunk {
    self.buffer.push(byte)
  }
  Ok(())
}

///|
pub fn FrameDecoder::next(self : FrameDecoder) -> FrameOutcome {
  if self.failed is Some(error) {
    return MalformedPacket(error)
  }
  if self.buffer.length() < 2 {
    return NeedMoreData
  }
  let mut remaining_length = 0
  let mut multiplier = 1
  let mut index = 1
  for digit_count in 1..<=4 {
    if index >= self.buffer.length() {
      return NeedMoreData
    }
    let encoded = self.buffer[index].to_int()
    remaining_length = remaining_length + (encoded & 0x7f) * multiplier
    index = index + 1
    if (encoded & 0x80) == 0 {
      let total_length = index + remaining_length
      if total_length > self.max_packet_size {
        let error = PacketTooLarge(total_length)
        self.failed = Some(error)
        return MalformedPacket(error)
      }
      if self.buffer.length() < total_length {
        return NeedMoreData
      }
      let frame = Bytes::from_array(self.buffer[:total_length].to_owned())
      self.buffer = self.buffer[total_length:].to_owned()
      return CompletePacket(frame)
    }
    if digit_count == 4 {
      self.failed = Some(InvalidRemainingLength)
      return MalformedPacket(InvalidRemainingLength)
    }
    multiplier = multiplier * 128
  }
  abort("unreachable remaining-length state")
}

///|
pub fn FrameDecoder::buffered_len(self : FrameDecoder) -> Int {
  self.buffer.length()
}

///|
pub fn FrameDecoder::reset(self : FrameDecoder) -> Unit {
  self.buffer.clear()
  self.failed = None
}
