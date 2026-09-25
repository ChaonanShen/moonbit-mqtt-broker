///|
fn lifecycle_startup() -> ManagementStartup {
  {
    config: @management.ManagementConfig::new(
      enabled=true,
      token_file="/fixture/tokens",
    ).unwrap(),
    tokens: @management.TokenDatabase::parse(
      @utf8.encode(
        "spike-token:dc211f3214c8dc9ccfdf0c2f2835ed515fc2e032d912934e1d700f8374747236:metrics,read\n",
      ),
    ).unwrap(),
  }
}

///|
async test "management startup owns a fixed parent and closes the bound socket" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let address = listener.addr
  let startup = lifecycle_startup()
  let runtime = ManagementRuntime::new(
    listener,
    startup,
    state.resource_ledger(),
  ).unwrap()
  assert_eq(
    state.resource_ledger().committed(),
    startup.config.required_bytes(),
  )
  runtime.close()
  runtime.close()
  assert_eq(state.resource_ledger().occupied(), 0L)
  let rebound = @socket.TcpServer(address, reuse_addr=true)
  rebound.close()
}

///|
async test "management startup budget failure leaves the broker ledger clear" {
  let startup = lifecycle_startup()
  let ledger = @budget.Ledger::new(startup.config.required_bytes() - 1L, 0L).unwrap()
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  assert_true(
    ManagementRuntime::new(listener, startup, ledger)
    is Err(ManagementStartupError::BudgetUnavailable),
  )
  listener.close()
  assert_eq(ledger.occupied(), 0L)
  assert_eq(ledger.live_tickets(), 0)
}

///|
async test "cancel accept task before closing management listener" {
  @async.with_task_group() <| group => {
    let config = ServerConfig::default()
    let state = @router.BrokerState::new(config.broker_config())
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    let address = listener.addr
    let runtime = ManagementRuntime::new(
      listener,
      lifecycle_startup(),
      state.resource_ledger(),
    ).unwrap()
    let task = group.spawn(() => runtime.run_acceptor())
    @async.sleep(30)
    task.cancel()
    task.wait() catch {
      _ => ()
    }
    runtime.close()
    let rebound = @socket.TcpServer(address, reuse_addr=true)
    rebound.close()
    assert_eq(state.resource_ledger().occupied(), 0L)
  }
}

///|
async test "driver observation event refreshes cache without broker mutation" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let management = ManagementRuntime::new(
    listener,
    lifecycle_startup(),
    state.resource_ledger(),
  ).unwrap()
  let runtime = BrokerRuntime::new(config, state)
  let driver = RouterDriver::new(runtime, management~)
  let before = state.snapshot_revision()
  driver.handle(ObservationDue)
  assert_true(management.cache.captured_at() is Some(_))
  assert_true(management.cache.status_body(@budget.monotonic_ms()) is Ok(_))
  assert_eq(state.snapshot_revision(), before)
  assert_eq(runtime.metrics().messages_sent(), 0L)
  management.close()
  assert_eq(state.resource_ledger().occupied(), 0L)
}

///|
async test "second listener bind failure releases first listener port" {
  let config = ServerConfig::default()
  let blocker = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let startup = lifecycle_startup()
  let enabled = @management.ManagementConfig::new(
    enabled=true,
    token_file="/fixture/tokens",
    listen=blocker.addr.to_string(),
  ).unwrap()
  let mut released = false
  // A free ephemeral port can be claimed by another test between close and rebind.
  for _ in 0..<8 {
    let first = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    let mqtt_address = first.addr
    first.close()
    let mut management_bind_failed = false
    let completed = @async.with_timeout_opt(1000, () => {
      run(
        mqtt_address.to_string(),
        config,
        @router.BrokerState::new(config.broker_config()),
        management={ config: enabled, tokens: startup.tokens },
      ) catch {
        ResourceStartupFailure(message) =>
          management_bind_failed = message == "management listener bind failed"
        _ => ()
      }
    })
    assert_true(completed is Some(_))
    if !management_bind_failed {
      continue
    }
    let rebound = Some(@socket.TcpServer(mqtt_address, reuse_addr=true)) catch {
      _ => None
    }
    match rebound {
      Some(listener) => {
        listener.close()
        released = true
        break
      }
      None => ()
    }
  }
  blocker.close()
  assert_true(released)
}

///|
async test "management accept failure drains auth worker and ledger" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  let baseline_tickets = state.resource_ledger().live_tickets()
  let password = @security.PasswordDatabase::parse(
    "sensor01:$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM\n",
  ).unwrap()
  let policy = @security.SecurityPolicy::new(
    allow_anonymous=false,
    passwords=password,
  )
  let mqtt_listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let management_listener = @socket.TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
  )
  let management = ManagementRuntime::new(
    management_listener,
    lifecycle_startup(),
    state.resource_ledger(),
  ).unwrap()
  // Enter serve with a mandatory management acceptor that cannot accept.
  management_listener.close()
  let completed = @async.with_timeout_opt(3000, () => {
    let mut failed = false
    serve(mqtt_listener, config, state, security=policy, management~) catch {
      _ => failed = true
    }
    assert_true(failed)
  })
  assert_true(completed is Some(_))
  management.close()
  mqtt_listener.close()
  assert_eq(state.resource_ledger().occupied(), 0L)
  assert_eq(state.resource_ledger().live_tickets(), baseline_tickets)
}

///|
async test "failed final snapshot still drains management ownership" {
  let config = ServerConfig::default()
  let state = @router.BrokerState::new(config.broker_config())
  ignore(
    state
    .apply(
      @router.CreateSessionWith({
        client_id: @session.ClientId::new("dirty-management").unwrap(),
        mode: @session.Persistent,
        attached: false,
      }),
    )
    .unwrap(),
  )
  assert_true(state.snapshot_revision() > 0L)
  let baseline_tickets = state.resource_ledger().live_tickets()
  let path = "/tmp/mqtt-management-final-failure-" +
    @management.new_boot_id().unwrap()
  let disk = @persistence.PersistenceConfig::new(
    path,
    debounce_ms=20L,
    max_delay_ms=20L,
    retry_ms=20L,
  ).unwrap()
  let store = @persistence.SnapshotStore::open(disk).unwrap()
  let persistence = PersistenceRuntime::new(store, disk).unwrap()
  // A closed sink cannot accept the final dirty revision.
  persistence.sink.close()
  let mqtt_listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let management_listener = @socket.TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
  )
  let management = ManagementRuntime::new(
    management_listener,
    lifecycle_startup(),
    state.resource_ledger(),
    persistence~,
  ).unwrap()
  let completed = @async.with_timeout_opt(3000, () => {
    let mut failed = false
    serve(
      mqtt_listener,
      config,
      state,
      persistence~,
      shutdown_requested=() => true,
      management~,
    ) catch {
      _ => failed = true
    }
    assert_true(failed)
  })
  assert_true(completed is Some(_))
  management.close()
  persistence.close()
  mqtt_listener.close()
  assert_eq(state.resource_ledger().live_tickets(), baseline_tickets)
}

///|
async test "repeated management startup and close returns fd and ticket baseline" {
  for _ in 0..<25 {
    let config = ServerConfig::default()
    let state = @router.BrokerState::new(config.broker_config())
    let ledger = state.resource_ledger()
    let baseline = ledger.live_tickets()
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    let address = listener.addr
    let runtime = ManagementRuntime::new(listener, lifecycle_startup(), ledger).unwrap()
    runtime.close()
    assert_eq(ledger.live_tickets(), baseline)
    let rebound = @socket.TcpServer(address, reuse_addr=true)
    rebound.close()
  }
}
