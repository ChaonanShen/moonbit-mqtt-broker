///|
let crc32_table : FixedArray[UInt] = FixedArray::makei(256, fn(index) {
  let mut crc = index.reinterpret_as_uint()
  for _ in 0..<8 {
    crc = if (crc & 1U) == 0U { crc >> 1 } else { (crc >> 1) ^ 0xedb88320U }
  }
  crc
})

///|
pub fn crc32(data : BytesView) -> UInt {
  let mut crc = 0xffffffffU
  for byte in data {
    let index = ((crc ^ byte.to_uint()) & 0xffU).reinterpret_as_int()
    crc = crc32_table[index] ^ (crc >> 8)
  }
  crc ^ 0xffffffffU
}
