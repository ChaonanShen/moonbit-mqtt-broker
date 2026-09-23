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
