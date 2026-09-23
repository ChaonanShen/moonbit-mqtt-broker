///|
/// Fixed-capacity metadata index. A live key never moves to another slot.
/// This package owns no broker payload or socket.
pub struct SlotIndex {
  slots : Array[String?]
  next_free : Array[Int]
  reverse : Map[String, Int]
  mut free_head : Int
  mut next_unused : Int
  mut live : Int
}

///|
pub(all) enum SlotInsert {
  Added(Int)
  Existing(Int)
  Full
} derive(Eq, Debug)

///|
pub(all) struct SlotPage {
  keys : Array[String]
  next_slot : Int
  scanned : Int
  has_more : Bool
} derive(Eq, Debug)

///|
pub fn SlotIndex::new(capacity : Int) -> SlotIndex {
  {
    slots: Array::make(capacity, None),
    next_free: Array::make(capacity, -1),
    reverse: Map([]),
    free_head: -1,
    next_unused: 0,
    live: 0,
  }
}

///|
pub fn SlotIndex::capacity(self : SlotIndex) -> Int {
  self.slots.length()
}

///|
pub fn SlotIndex::live_count(self : SlotIndex) -> Int {
  self.live
}

///|
pub fn SlotIndex::free_count(self : SlotIndex) -> Int {
  self.slots.length() - self.live
}

///|
pub fn SlotIndex::get(self : SlotIndex, key : String) -> Int? {
  self.reverse.get(key)
}

///|
pub fn SlotIndex::key_at(self : SlotIndex, slot : Int) -> String? {
  if slot < 0 || slot >= self.slots.length() {
    None
  } else {
    self.slots[slot]
  }
}

///|
pub fn SlotIndex::put(self : SlotIndex, key : String) -> SlotInsert {
  if self.reverse.get(key) is Some(slot) {
    return Existing(slot)
  }
  let slot = if self.free_head >= 0 {
    let reused = self.free_head
    self.free_head = self.next_free[reused]
    self.next_free[reused] = -1
    reused
  } else if self.next_unused < self.slots.length() {
    let fresh = self.next_unused
    self.next_unused += 1
    fresh
  } else {
    return Full
  }
  self.slots[slot] = Some(key)
  self.reverse.set(key, slot)
  self.live += 1
  Added(slot)
}

///|
pub fn SlotIndex::remove(self : SlotIndex, key : String) -> Bool {
  match self.reverse.get(key) {
    None => false
    Some(slot) => {
      self.reverse.remove(key)
      self.slots[slot] = None
      self.next_free[slot] = self.free_head
      self.free_head = slot
      self.live -= 1
      true
    }
  }
}

///|
/// Scans at most scan_limit physical slots, including empty and filtered
/// slots. A sparse filter may produce an empty page with a continuation.
pub fn SlotIndex::page(
  self : SlotIndex,
  start : Int,
  scan_limit : Int,
  limit : Int,
  accept : (String) -> Bool,
) -> SlotPage {
  let keys : Array[String] = []
  let capacity = self.slots.length()
  let mut position = if start < 0 { 0 } else { start }
  let mut scanned = 0
  if scan_limit > 0 && limit > 0 {
    while position < capacity && scanned < scan_limit && keys.length() < limit {
      if self.slots[position] is Some(key) && accept(key) {
        keys.push(key)
      }
      position += 1
      scanned += 1
    }
  }
  { keys, next_slot: position, scanned, has_more: position < capacity }
}

///|
pub fn SlotIndex::check_invariants(self : SlotIndex) -> Bool {
  let capacity = self.slots.length()
  if self.next_unused < 0 ||
    self.next_unused > capacity ||
    self.live < 0 ||
    self.live != self.reverse.length() {
    return false
  }
  let seen = Array::make(capacity, false)
  let mut free = self.free_head
  let mut free_count = 0
  while free >= 0 {
    if free >= self.next_unused || seen[free] || self.slots[free] is Some(_) {
      return false
    }
    seen[free] = true
    free_count += 1
    free = self.next_free[free]
  }
  let mut occupied = 0
  for slot in 0..<self.next_unused {
    match self.slots[slot] {
      Some(key) => {
        if seen[slot] || self.reverse.get(key) != Some(slot) {
          return false
        }
        occupied += 1
      }
      None => if !seen[slot] { return false }
    }
  }
  for slot in self.next_unused..<capacity {
    if self.slots[slot] is Some(_) || seen[slot] {
      return false
    }
  }
  occupied == self.live && occupied + free_count == self.next_unused
}
