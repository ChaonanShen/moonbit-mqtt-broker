///|
pub struct Bucket {
  capacity : Int64
  rate : Int64
  priv mut available : Int64
  priv mut last_ms : Int64
  priv mut remainder : Int64
}

///|
pub fn Bucket::new(
  rate : Int64,
  burst : Int64,
  now_ms : Int64,
) -> Result[Bucket, BudgetError] {
  if rate < 0L || burst < 0L || now_ms < 0L {
    return Err(InvalidConfiguration)
  }
  Ok({ capacity: burst, rate, available: burst, last_ms: now_ms, remainder: 0L })
}

///|
/// Splits multiplication before it can overflow, saturating at burst.
fn Bucket::preview(self : Bucket, now_ms : Int64) -> (Int64, Int64, Int64) {
  if now_ms <= self.last_ms {
    return (self.available, self.remainder, self.last_ms)
  }
  if self.rate == 0L {
    return (self.available, 0L, now_ms)
  }
  let needed = self.capacity - self.available
  if needed == 0L {
    return (self.capacity, 0L, now_ms)
  }
  let elapsed = now_ms - self.last_ms
  let seconds = elapsed / 1000L
  let fraction = elapsed % 1000L
  if seconds > needed / self.rate {
    return (self.capacity, 0L, now_ms)
  }
  let whole = seconds * self.rate
  if whole >= needed {
    return (self.capacity, 0L, now_ms)
  }
  let small = self.rate % 1000L * fraction + self.remainder
  let partial = self.rate / 1000L * fraction + small / 1000L
  if partial >= needed - whole {
    return (self.capacity, 0L, now_ms)
  }
  (self.available + whole + partial, small % 1000L, now_ms)
}

///|
/// All keys commit together. Refills and debits are unchanged on rejection.
/// At most 16 keys per attempt; duplicate keys are coalesced before mutation.
pub fn admit(
  requests : Array[(Bucket, Int64)],
  now_ms : Int64,
) -> Result[Unit, BudgetError] {
  if now_ms < 0L || requests.length() > 16 {
    return Err(InvalidConfiguration)
  }
  let buckets : Array[Bucket] = []
  let costs : Array[Int64] = []
  for request in requests {
    let (bucket, cost) = request
    if cost < 0L {
      return Err(InvalidAmount)
    }
    let mut found = false
    for i in 0..<buckets.length() {
      if physical_equal(buckets[i], bucket) {
        costs[i] = match checked_add(costs[i], cost) {
          Ok(n) => n
          Err(e) => return Err(e)
        }
        found = true
        break
      }
    }
    if !found {
      buckets.push(bucket)
      costs.push(cost)
    }
  }
  let updates : Array[(Int64, Int64, Int64)] = []
  for i in 0..<buckets.length() {
    let (available, remainder, last) = buckets[i].preview(now_ms)
    if costs[i] > available {
      return Err(
        Exhausted(
          Global,
          "rate",
          buckets[i].capacity - available,
          costs[i],
          buckets[i].capacity,
        ),
      )
    }
    updates.push((available - costs[i], remainder, last))
  }
  for i in 0..<buckets.length() {
    let (available, remainder, last) = updates[i]
    buckets[i].available = available
    buckets[i].remainder = remainder
    buckets[i].last_ms = last
  }
  Ok(())
}

///|
pub fn Bucket::available_at(self : Bucket, now_ms : Int64) -> Int64 {
  let (available, _, _) = self.preview(now_ms)
  available
}

///|
pub fn Bucket::full_at(self : Bucket, now_ms : Int64) -> Bool {
  self.available_at(now_ms) == self.capacity
}
