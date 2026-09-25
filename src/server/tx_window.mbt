///|
pub(all) struct TxLease {
  delivery_id : Int64
  generation : Int64
} derive(Eq, Debug)

///|
pub(all) enum TxReserveResult {
  TxReserved(TxLease)
  TxAlreadyReserved(TxLease)
  TxWindowFull
  TxInvalidDelivery
} derive(Eq, Debug)

///|
pub struct TxWindow {
  initial : Int
  mut available : Int
  leases : Map[Int64, TxLease]
  mut next_generation : Int64
}

///|
pub fn TxWindow::new(initial : Int) -> TxWindow {
  { initial, available: initial, leases: Map([]), next_generation: 1L }
}

///|
pub fn TxWindow::available(self : TxWindow) -> Int {
  self.available
}

///|
pub fn TxWindow::reserve(
  self : TxWindow,
  delivery_id : Int64,
) -> TxReserveResult {
  if delivery_id < 1L || self.initial < 1 {
    return TxInvalidDelivery
  }
  if self.leases.get(delivery_id) is Some(existing) {
    return TxAlreadyReserved(existing)
  }
  if self.available < 1 || self.next_generation == 9223372036854775807L {
    return TxWindowFull
  }
  let lease = TxLease::{ delivery_id, generation: self.next_generation }
  self.next_generation += 1L
  self.available -= 1
  self.leases.set(delivery_id, lease)
  TxReserved(lease)
}

///|
pub fn TxWindow::terminal(self : TxWindow, lease : TxLease) -> Bool {
  if self.leases.get(lease.delivery_id) != Some(lease) {
    return false
  }
  self.leases.remove(lease.delivery_id)
  self.available += 1
  true
}

///|
pub fn TxWindow::close(self : TxWindow) -> Unit {
  self.leases.clear()
  self.available = self.initial
}
