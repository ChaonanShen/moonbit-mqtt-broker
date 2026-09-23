///|
fn mailbox_spec() -> @management.QuerySpec {
  {
    kind: @management.Sessions,
    target: "",
    actor_token_id: "reader",
    limit: 1,
    cursor: None,
    filters: "",
  }
}

///|
test "query slot generation rejects late producer after abandonment and reuse" {
  let mailbox = ManagementQueryMailbox::new(1)
  let first = mailbox.submit(mailbox_spec()).unwrap()
  let stale = mailbox.take().unwrap()
  assert_eq(stale.ticket, first)
  mailbox.release(first)
  let second = mailbox.submit(mailbox_spec()).unwrap()
  assert_true(second.generation > first.generation)
  mailbox.produce(first, { status: @http_transport.Ok, body: b"stale" })
  assert_false(mailbox.slots[0].ready)
  mailbox.produce(second, { status: @http_transport.Ok, body: b"current" })
  assert_true(mailbox.slots[0].ready)
  assert_eq(mailbox.slots[0].reply.unwrap().body, b"current")
  mailbox.release(second)
  assert_eq(mailbox.active_count(), 0)
}

///|
async test "EventBus serves queued management within eight non-management events" {
  let (bus, state) = observation_bus_fixture()
  let mailbox = ManagementQueryMailbox::new(1)
  bus.attach_management_queries(mailbox)
  let ticket = mailbox.submit(mailbox_spec()).unwrap()
  for index in 0..<8 {
    bus.post_tick(CheckDeadlines(index.to_int64()))
    assert_true(bus.next() is Some(Runtime(CheckDeadlines(_))))
  }
  assert_true(bus.next() is Some(ManagementQuery({ ticket: _, .. })))
  mailbox.release(ticket)
  bus.close()
  assert_eq(state.managed_bytes(), 0L)
}
