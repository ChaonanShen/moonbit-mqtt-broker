///|
test "all exported broker counters saturate without negative wrap" {
  let metrics = BrokerMetrics::new(0L)
  let max = 9223372036854775807L
  metrics.messages_received = max - 1L
  metrics.messages_sent = max - 1L
  metrics.auth_requests = max - 1L
  metrics.qos2_received = max - 1L
  metrics.qos2_duplicates = max - 1L
  metrics.tls_handshake_failures = max - 1L
  for _ in 0..<2 {
    metrics.record_received()
    metrics.record_sent()
    metrics.record_auth_request()
    metrics.record_qos2(duplicate=true)
    metrics.record_tls_handshake_failure()
  }
  assert_eq(metrics.messages_received(), max)
  assert_eq(metrics.messages_sent(), max)
  assert_eq(metrics.auth_requests(), max)
  assert_eq(metrics.qos2_received(), max)
  assert_eq(metrics.qos2_duplicates(), max)
  assert_eq(metrics.tls_handshake_failures(), max)
}
