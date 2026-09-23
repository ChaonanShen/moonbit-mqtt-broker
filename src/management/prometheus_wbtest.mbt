///|
test "management rejection categories saturate and cannot add labels" {
  let counters = ManagementRejections::new()
  let max = 9223372036854775807L
  counters.counts[RejectedAuth.index()] = max - 1L
  counters.record(RejectedAuth)
  counters.record(RejectedAuth)
  assert_eq(counters.value(RejectedAuth), max)
  assert_eq(counters.counts.length(), 8)
}
