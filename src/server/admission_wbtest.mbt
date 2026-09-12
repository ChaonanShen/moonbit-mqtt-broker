///|
fn admission_fixture(
  overrides : Array[(String, Int64)],
  clock : () -> Int64,
) -> (AdmissionState, @router.BrokerState) {
  let mut resources = @budget.Limits::default()
  for entry in overrides {
    let (key, value) = entry
    resources = resources.with_value(key, value).unwrap()
  }
  let broker = @router.BrokerConfig::new(4, 8, 4, resources~).unwrap()
  let config = ServerConfig::new(16, 1024, 1024, 4, 4, 1000, 100, broker).unwrap()
  let state = @router.BrokerState::new(broker)
  (AdmissionState::new(config, state.resource_ledger(), clock~), state)
}

///|
test "canonical socket peers collapse ports mapped IPv4 and IPv6 representations" {
  assert_eq(canonical_ip(@socket.Addr::parse("127.0.0.1:10")), "127.0.0.1")
  assert_eq(
    canonical_ip(@socket.Addr::parse("[::ffff:7f00:1]:20")),
    "127.0.0.1",
  )
  assert_eq(
    canonical_ip(@socket.Addr::parse("[0:0:0:0:0:0:0:1]:20")),
    canonical_ip(@socket.Addr::parse("[::1]:30")),
  )
}

///|
test "connection gate owns preTLS lifetime and does not release twice" {
  let (admission, state) = admission_fixture([("max_connections_per_ip", 1L)], () => {
    0L
  })
  assert_true(admission.accept(ConnectionId::new(1L), "a"))
  assert_false(admission.accept(ConnectionId::new(2L), "a"))
  assert_true(admission.accept(ConnectionId::new(3L), "b"))
  admission.release(ConnectionId::new(1L))
  admission.release(ConnectionId::new(1L))
  assert_eq(admission.live, 1)
  assert_true(admission.accept(ConnectionId::new(4L), "a"))
  admission.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
test "IP ttl cannot erase token debt or registered pending references" {
  let time = Ref(0L)
  let (admission, state) = admission_fixture(
    [
      ("connect_rate_per_ip", 1L),
      ("connect_burst_per_ip", 1L),
      ("idle_ttl_ms", 1L),
    ],
    () => time.val,
  )
  let id = ConnectionId::new(1L)
  assert_true(admission.accept(id, "a"))
  admission.registered(id)
  admission.release(id)
  time.val = 2000L
  admission.cleanup_ips(time.val)
  assert_eq(admission.ips.length(), 1)
  admission.forget(id)
  admission.cleanup_ips(time.val)
  assert_eq(admission.ips.length(), 0)
  assert_true(admission.accept(ConnectionId::new(2L), "a"))
  admission.release(ConnectionId::new(2L))
  time.val = 2002L
  admission.cleanup_ips(time.val)
  assert_eq(admission.ips.length(), 1)
  assert_false(admission.accept(ConnectionId::new(3L), "a"))
  time.val = 3000L
  assert_true(admission.accept(ConnectionId::new(4L), "a"))
  admission.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
test "global rejection does not create arbitrary IP keys and key table is bounded" {
  let (admission, state) = admission_fixture(
    [
      ("connect_rate_total", 0L),
      ("connect_burst_total", 1L),
      ("max_ip_buckets", 1L),
    ],
    () => 0L,
  )
  assert_true(admission.accept(ConnectionId::new(1L), "a"))
  for i in 2..<=100 {
    assert_false(
      admission.accept(
        ConnectionId::new(i.to_int64()),
        "random-" + i.to_string(),
      ),
    )
  }
  assert_eq(admission.ips.length(), 1)
  admission.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
test "auth attempt tokens are separate from connection and memory lifetime" {
  let (admission, state) = admission_fixture(
    [("auth_rate_total", 0L), ("auth_burst_total", 1L)],
    () => 0L,
  )
  let id = ConnectionId::new(1L)
  assert_true(admission.accept(id, "a"))
  assert_true(admission.admit_auth(id))
  admission.release(id)
  assert_false(admission.admit_auth(id))
  admission.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
test "ingress bills actual bytes once and publish buckets survive persistent reconnect" {
  let (admission, state) = admission_fixture(
    [
      ("ingress_bytes_total", 0L),
      ("ingress_bytes_burst_total", 10L),
      ("publish_messages_per_session", 0L),
      ("publish_messages_burst_per_session", 1L),
    ],
    () => 0L,
  )
  let transport = ConnectionId::new(1L)
  assert_true(admission.accept(transport, "a"))
  assert_true(admission.admit_ingress(transport, 10L))
  assert_false(admission.admit_ingress(transport, 1L))
  let id = @session.ClientId::new("persistent").unwrap()
  ignore(
    state
    .apply(
      @router.CreateSessionWith({
        client_id: id,
        mode: @session.Persistent,
        attached: true,
      }),
    )
    .unwrap(),
  )
  assert_true(admission.admit_publish(id, 1L))
  admission.release(transport)
  admission.prune_publishers(state)
  assert_false(admission.admit_publish(id, 1L))
  ignore(state.apply(@router.RemoveSession(id)).unwrap())
  admission.prune_publishers(state)
  assert_eq(admission.publishers.length(), 0)
  admission.close()
  assert_eq(state.managed_bytes(), 0L)
}

///|
test "IP cleanup needs no new budget reservation and keeps its rotation bounded" {
  let now = Ref(0L)
  let (admission, state) = admission_fixture(
    [("rate_limits_enabled", 0L), ("idle_ttl_ms", 1L)],
    () => now.val,
  )
  for i in 0..<80 {
    let id = ConnectionId::new(i.to_int64() + 1L)
    assert_true(admission.accept(id, "ip-" + i.to_string()))
    admission.release(id)
  }
  assert_eq(admission.ips.length(), 80)
  assert_eq(admission.ip_order.length(), 80)
  let ledger = state.resource_ledger()
  let control = ledger
    .pool(ControlWork, 2097152L)
    .unwrap()
    .reserve(2097152L)
    .unwrap()
  now.val = 2L
  admission.cleanup_ips(now.val)
  assert_eq(admission.ips.length(), 48)
  admission.cleanup_ips(now.val)
  admission.cleanup_ips(now.val)
  assert_eq(admission.ips.length(), 0)
  assert_eq(admission.ip_order.length(), 0)
  control.release().unwrap()
  admission.close()
  assert_eq(state.managed_bytes(), 0L)
}
