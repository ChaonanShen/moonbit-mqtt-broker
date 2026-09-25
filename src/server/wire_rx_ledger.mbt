///|
pub(all) struct RxPermit {
  packet_id : Int
  generation : Int64
  qos : Int
} derive(Eq, Debug)

///|
pub(all) enum RxReserveResult {
  RxNew(RxPermit)
  RxDuplicateQoS2(RxPermit)
  RxPacketIdInUse
  RxQuotaExceeded
  RxInvalidPacketId
} derive(Eq, Debug)

///|
pub struct WireRxLedger {
  capacity : Int
  entries : Map[Int, RxPermit]
  mut next_generation : Int64
}

///|
pub fn WireRxLedger::new(capacity : Int) -> WireRxLedger {
  { capacity, entries: Map([]), next_generation: 1L }
}

///|
pub fn WireRxLedger::count(self : WireRxLedger) -> Int {
  self.entries.length()
}

///|
pub fn WireRxLedger::reserve(
  self : WireRxLedger,
  packet_id : Int,
  qos : Int,
) -> RxReserveResult {
  if packet_id < 1 || packet_id > 65535 || (qos != 1 && qos != 2) {
    return RxInvalidPacketId
  }
  if self.entries.get(packet_id) is Some(existing) {
    if qos == 2 && existing.qos == 2 {
      return RxDuplicateQoS2(existing)
    }
    return RxPacketIdInUse
  }
  if self.capacity < 1 || self.entries.length() >= self.capacity {
    return RxQuotaExceeded
  }
  if self.next_generation < 1L || self.next_generation == 9223372036854775807L {
    return RxQuotaExceeded
  }
  let permit = RxPermit::{ packet_id, qos, generation: self.next_generation }
  self.next_generation += 1L
  self.entries.set(packet_id, permit)
  RxNew(permit)
}

///|
/// Only a writer receipt for a terminal acknowledgement can release a permit.
pub fn WireRxLedger::complete(self : WireRxLedger, permit : RxPermit) -> Bool {
  if self.entries.get(permit.packet_id) != Some(permit) {
    return false
  }
  self.entries.remove(permit.packet_id)
  true
}

///|
pub fn WireRxLedger::close(self : WireRxLedger) -> Unit {
  self.entries.clear()
}

///|
pub fn WireRxLedger::permit(self : WireRxLedger, packet_id : Int) -> RxPermit? {
  self.entries.get(packet_id)
}
