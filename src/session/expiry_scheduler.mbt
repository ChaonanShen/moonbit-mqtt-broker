///|
pub(all) struct ExpiryEntry {
  key : String
  due_mono_ms : Int64
  revision : Int64
  cost_bytes : Int64
} derive(Eq, Debug)

///|
/// Indexed min-heap: every live key has exactly one node, so replacements and
/// deletions cannot accumulate stale timer entries.
pub struct ExpiryScheduler {
  heap : Array[ExpiryEntry]
  positions : Map[String, Int]
  mut used_bytes : Int64
  max_entries : Int
  max_bytes : Int64
} derive(Eq, Debug)

///|
pub fn ExpiryScheduler::new(
  max_entries : Int,
  max_bytes : Int64,
) -> ExpiryScheduler {
  { heap: [], positions: Map([]), used_bytes: 0L, max_entries, max_bytes }
}

///|
pub fn ExpiryScheduler::length(self : ExpiryScheduler) -> Int {
  self.heap.length()
}

///|
pub fn ExpiryScheduler::used_bytes(self : ExpiryScheduler) -> Int64 {
  self.used_bytes
}

///|
fn expiry_before(left : ExpiryEntry, right : ExpiryEntry) -> Bool {
  left.due_mono_ms < right.due_mono_ms ||
  (left.due_mono_ms == right.due_mono_ms && left.key < right.key)
}

///|
fn ExpiryScheduler::swap(
  self : ExpiryScheduler,
  left : Int,
  right : Int,
) -> Unit {
  let first = self.heap[left]
  let second = self.heap[right]
  self.heap[left] = second
  self.heap[right] = first
  self.positions.set(second.key, left)
  self.positions.set(first.key, right)
}

///|
fn ExpiryScheduler::sift_up(self : ExpiryScheduler, index : Int) -> Unit {
  let mut current = index
  while current > 0 {
    let parent = (current - 1) / 2
    if !expiry_before(self.heap[current], self.heap[parent]) {
      break
    }
    self.swap(current, parent)
    current = parent
  }
}

///|
fn ExpiryScheduler::sift_down(self : ExpiryScheduler, index : Int) -> Unit {
  let mut current = index
  for ;; {
    let left = current * 2 + 1
    if left >= self.heap.length() {
      break
    }
    let right = left + 1
    let mut smallest = left
    if right < self.heap.length() &&
      expiry_before(self.heap[right], self.heap[left]) {
      smallest = right
    }
    if !expiry_before(self.heap[smallest], self.heap[current]) {
      break
    }
    self.swap(current, smallest)
    current = smallest
  }
}

///|
pub fn ExpiryScheduler::projected_set_delta(
  self : ExpiryScheduler,
  key : String,
) -> Int64 {
  let cost = 96L + @utf8.encode(key).length().to_int64()
  cost - self.get(key).map(entry => entry.cost_bytes).unwrap_or(0L)
}

///|
pub fn ExpiryScheduler::can_set(self : ExpiryScheduler, key : String) -> Bool {
  if key == "" {
    return false
  }
  let cost = 96L + @utf8.encode(key).length().to_int64()
  let before = self.positions.get(key)
  let previous = before.map(index => self.heap[index].cost_bytes).unwrap_or(0L)
  (before is Some(_) || self.heap.length() < self.max_entries) &&
  cost <= self.max_bytes - self.used_bytes + previous
}

///|
pub fn ExpiryScheduler::set(
  self : ExpiryScheduler,
  key : String,
  due_mono_ms : Int64,
  revision : Int64,
) -> Bool {
  if key == "" || due_mono_ms < 0L || revision < 0L {
    return false
  }
  let cost = 96L + @utf8.encode(key).length().to_int64()
  let before = self.positions.get(key)
  let previous = before.map(index => self.heap[index].cost_bytes).unwrap_or(0L)
  if (before is None && self.heap.length() >= self.max_entries) ||
    cost > self.max_bytes - self.used_bytes + previous {
    return false
  }
  let value : ExpiryEntry = { key, due_mono_ms, revision, cost_bytes: cost }
  self.used_bytes += cost - previous
  match before {
    Some(index) => {
      self.heap[index] = value
      self.sift_up(index)
      self.sift_down(self.positions.get(key).unwrap())
    }
    None => {
      let index = self.heap.length()
      self.heap.push(value)
      self.positions.set(key, index)
      self.sift_up(index)
    }
  }
  true
}

///|
pub fn ExpiryScheduler::remove(self : ExpiryScheduler, key : String) -> Bool {
  let index = match self.positions.get(key) {
    Some(value) => value
    None => return false
  }
  let old = self.heap[index]
  self.positions.remove(key)
  self.used_bytes -= old.cost_bytes
  let last = self.heap.pop().unwrap()
  if index < self.heap.length() {
    self.heap[index] = last
    self.positions.set(last.key, index)
    self.sift_up(index)
    self.sift_down(self.positions.get(last.key).unwrap())
  }
  true
}

///|
pub fn ExpiryScheduler::get(
  self : ExpiryScheduler,
  key : String,
) -> ExpiryEntry? {
  self.positions.get(key).map(index => self.heap[index])
}

///|
pub fn ExpiryScheduler::peek_due(
  self : ExpiryScheduler,
  now_mono_ms : Int64,
) -> ExpiryEntry? {
  if self.heap.is_empty() || self.heap[0].due_mono_ms > now_mono_ms {
    None
  } else {
    Some(self.heap[0])
  }
}

///|
pub fn ExpiryScheduler::copy(self : ExpiryScheduler) -> ExpiryScheduler {
  let positions : Map[String, Int] = Map([])
  for key, index in self.positions {
    positions.set(key, index)
  }
  {
    heap: self.heap.copy(),
    positions,
    used_bytes: self.used_bytes,
    max_entries: self.max_entries,
    max_bytes: self.max_bytes,
  }
}

///|
pub fn ExpiryScheduler::check_invariants(self : ExpiryScheduler) -> Bool {
  if self.heap.length() != self.positions.length() ||
    self.heap.length() > self.max_entries ||
    self.used_bytes > self.max_bytes {
    return false
  }
  let mut used = 0L
  for index in 0..<self.heap.length() {
    let entry = self.heap[index]
    if self.positions.get(entry.key) != Some(index) {
      return false
    }
    if index > 0 && expiry_before(entry, self.heap[(index - 1) / 2]) {
      return false
    }
    used += entry.cost_bytes
  }
  used == self.used_bytes
}
