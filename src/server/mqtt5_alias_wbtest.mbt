///|
test "C-T22 cancelled alias definition cannot be reused" {
  let sink = TransportSink::new(4)
  let first = sink.propose_outbound_alias("sensors/a", 4, 4096)
  assert_eq(first, AliasDefine(1, "sensors/a"))
  assert_eq(sink.propose_outbound_alias("sensors/a", 4, 4096), AliasNone)
  sink.outbound_alias_cancel(first)
  let second = sink.propose_outbound_alias("sensors/a", 4, 4096)
  assert_eq(second, AliasDefine(2, "sensors/a"))
  sink.outbound_alias_written(second)
  assert_eq(sink.propose_outbound_alias("sensors/a", 4, 4096), AliasReuse(2))
  sink.close()
}

///|
test "C-T22 alias budget prevents uncharged definitions" {
  let sink = TransportSink::new(4)
  assert_eq(sink.propose_outbound_alias("long/topic", 4, 5), AliasNone)
  let first = sink.propose_outbound_alias("long/topic", 4, 74)
  assert_eq(first, AliasDefine(1, "long/topic"))
  assert_eq(sink.propose_outbound_alias("other/topic", 4, 74), AliasNone)
  sink.close()
}
